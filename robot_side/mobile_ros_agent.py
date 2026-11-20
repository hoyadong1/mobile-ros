#!/usr/bin/env python3
"""Connects a robot to the Mobile ROS relay, so the app can reach it from anywhere on the internet.

The robot opens an OUTGOING connection to the relay (no port forwarding, no public IP). For every app
session the relay announces, the agent opens a connection to the robot's own rosbridge and passes the
messages through unchanged.

Safety, on the robot's side, whatever the internet does:
  * a velocity command that is not repeated within --stop-after (0.5 s) is followed by zero velocity;
  * when a session ends or the relay connection drops, every topic that was moving gets zero velocity.
  * action goals sent by this session are canceled when the session ends.
The base's own safety (bumpers, its command timeout, Nav2's collision checks) still applies.

Run on the robot, next to rosbridge (it uses tornado, which rosbridge_server already installed):
    export MOBILE_ROS_AGENT_TOKEN=...      # the robot token from `node relay.mjs add-robot <id>`
    python3 mobile_ros_agent.py --relay wss://relay.example.com/agent
The token is read from the environment or --token-file, never from the command line (other users of
the machine can see command lines).
"""
import argparse
import json
import os
import re
import sys
import time

from tornado import gen, ioloop
from tornado.httpclient import HTTPRequest
from tornado.websocket import websocket_connect

TWIST = {"geometry_msgs/msg/Twist", "geometry_msgs/Twist"}
TWIST_STAMPED = {"geometry_msgs/msg/TwistStamped", "geometry_msgs/TwistStamped"}
READ_SERVICE = re.compile(r'^/rosapi/(topics|topics_and_raw_types|topic_type|publishers|subscribers|services|service_type|service_node|service_providers|nodes|node_details|action_servers|interfaces|message_details|service_request_details|service_response_details|get_param|get_param_names|has_param)$')


def zero_for(type_name):
    zero = {"linear": {"x": 0.0, "y": 0.0, "z": 0.0}, "angular": {"x": 0.0, "y": 0.0, "z": 0.0}}
    return {"header": {"frame_id": ""}, "twist": zero} if type_name in TWIST_STAMPED else zero


def is_moving(msg):
    t = msg.get("twist", msg) if isinstance(msg, dict) else {}
    if not isinstance(t, dict):
        return True
    for part in ('linear', 'angular'):
        vector = t.get(part) or {}
        if not isinstance(vector, dict) or any(vector.get(k, 0) for k in ('x', 'y', 'z')):
            return True
    return False


class Session:
    """One app's connection through the relay, as one local rosbridge connection."""

    def __init__(self, agent, sid, role):
        self.agent, self.sid, self.role = agent, sid, role
        self.local = None
        self.pending = []
        self.types = {}      # topic -> message type (from the app's advertise)
        self.moving = {}     # topic -> time of the last non-zero command
        self.actions = {}    # this session's rosbridge action goal IDs -> action names
        self.closed = False

    async def open(self):
        try:
            local = await websocket_connect(self.agent.rosbridge, max_message_size=256 * 1024 * 1024)
            if self.closed:
                local.close()
                return
            self.local = local
        except Exception as e:  # rosbridge not running
            self.agent.send({"session": self.sid, "close": True, "reason": f"Robot rosbridge unavailable: {e}"})
            self.closed = True
            return
        for text in self.pending:
            self.from_app(text)
        self.pending = []
        try:
            while not self.closed:
                text = await self.local.read_message()
                if text is None:
                    break
                try:
                    reply = json.loads(text)
                    if isinstance(reply, dict) and reply.get('op') == 'action_result':
                        self.actions.pop(reply.get('id'), None)
                except (ValueError, TypeError):
                    pass
                self.agent.send({"session": self.sid, "data": text})
        finally:
            if not self.closed:
                self.agent.send({"session": self.sid, "close": True, "reason": "Robot rosbridge closed."})
                self.close()
            if self.agent.sessions.get(self.sid) is self:
                self.agent.sessions.pop(self.sid, None)

    def from_app(self, text, sent_at=None, max_age_ms=None):
        if self.closed:
            return
        try:
            m = json.loads(text)
        except ValueError:
            return
        if not isinstance(m, dict):
            return
        # Cloud control frames expire in transit. Robot/server clocks must be synchronized.
        if m.get('op') in ('publish', 'send_action_goal', 'call_service') and sent_at is not None:
            age = time.time() * 1000 - sent_at if isinstance(sent_at, (int, float)) else float('inf')
            if not isinstance(max_age_ms, (int, float)) or not 0 < max_age_ms <= 500 or not -5000 <= age <= max_age_ms:
                self.close()
                self.agent.send({'session': self.sid, 'close': True, 'reason': 'Stale remote command or unsynchronized clocks.'})
                return
        # Never queue control commands while rosbridge is opening: an old command must not start
        # movement later. Discovery/subscriptions/advertisements may wait for the connection.
        if self.local is None:
            readonly = m.get('op') == 'call_service' and READ_SERVICE.fullmatch(str(m.get('service', '')))
            if not readonly and m.get('op') in ('publish', 'call_service', 'send_action_goal', 'cancel_action_goal'):
                self.agent.send({'session': self.sid, 'data': json.dumps({
                    'op': 'status', 'level': 'error', 'id': m.get('id'),
                    'msg': 'Robot connection is opening. Retry when ready.'})})
                if m.get('op') == 'call_service':
                    self.agent.send({'session': self.sid, 'data': json.dumps({
                        'op': 'service_response', 'id': m.get('id'), 'service': m.get('service'),
                        'result': False, 'values': 'Robot connection is opening.'})})
                return
            if len(self.pending) >= 256:
                self.close()
                self.agent.send({'session': self.sid, 'close': True, 'reason': 'Too many pending messages.'})
            else:
                self.pending.append(text)
            return
        if m.get("op") == "advertise" and m.get("type") in TWIST | TWIST_STAMPED:
            self.types[m.get("topic")] = m["type"]
        if m.get('op') == 'unadvertise' and m.get('topic') in self.moving:
            self.stop(m['topic'])
        if m.get('op') == 'send_action_goal' and isinstance(m.get('id'), str) and isinstance(m.get('action'), str):
            self.actions[m['id']] = m['action']
        if m.get("op") == "publish" and m.get("topic") in self.types:
            if is_moving(m.get("msg") or {}):
                self.moving[m["topic"]] = time.monotonic()
            else:
                self.moving.pop(m["topic"], None)
        try:
            self.local.write_message(text)
        except Exception:
            self.close()

    def stop_stale(self, limit):
        now = time.monotonic()
        for topic, last in list(self.moving.items()):
            if now - last > limit:
                self.stop(topic)

    def stop(self, topic):
        self.moving.pop(topic, None)
        if self.local is not None:
            try:
                self.local.write_message(json.dumps({"op": "publish", "topic": topic, "msg": zero_for(self.types.get(topic))}))
            except Exception:
                pass  # local bridge is lost: the base's own command timeout must stop it
            print(f"[agent] {topic}: no fresh command, stopped", flush=True)

    def close(self):
        if self.closed:
            return
        for topic in list(self.moving):
            self.stop(topic)
        if self.local is not None:
            for goal_id, action in self.actions.items():
                try:
                    self.local.write_message(json.dumps({'op': 'cancel_action_goal', 'id': goal_id, 'action': action}))
                except Exception:
                    pass
        self.actions.clear()
        self.closed = True
        self.pending.clear()
        if self.local is not None:
            self.local.close()


class Agent:
    def __init__(self, relay, token, rosbridge, stop_after):
        self.relay, self.token, self.rosbridge, self.stop_after = relay, token, rosbridge, stop_after
        self.ws = None
        self.sessions = {}

    def send(self, frame):
        if self.ws is not None:
            try:
                self.ws.write_message(json.dumps(frame))
            except Exception:
                pass

    async def run(self):
        ioloop.PeriodicCallback(self.watch, 100).start()
        delay = 1
        while True:
            try:
                request = HTTPRequest(self.relay, headers={"Authorization": f"Bearer {self.token}"})
                self.ws = await websocket_connect(request, ping_interval=10, ping_timeout=20,
                                                  max_message_size=64 * 1024 * 1024)
                print(f"[agent] connected to {self.relay}", flush=True)
                delay = 1
                while True:
                    text = await self.ws.read_message()
                    if text is None:
                        break
                    self.on_frame(text)
            except Exception as e:
                print(f"[agent] relay: {e}", flush=True)
            # The relay is gone: nothing from the app can arrive, so stop what was moving.
            self.ws = None
            for session in list(self.sessions.values()):
                session.close()
            self.sessions.clear()
            await gen.sleep(delay)
            delay = min(delay * 2, 30)

    def on_frame(self, text):
        try:
            frame = json.loads(text)
        except ValueError:
            return
        if not isinstance(frame, dict):
            return
        sid = frame.get("session")
        if frame.get("open"):
            old = self.sessions.pop(sid, None)
            if old:
                old.close()
            session = Session(self, sid, frame.get("role", "viewer"))
            self.sessions[sid] = session
            ioloop.IOLoop.current().spawn_callback(session.open)
        elif frame.get("close"):
            session = self.sessions.pop(sid, None)
            if session:
                session.close()
        elif isinstance(frame.get("data"), str) and sid in self.sessions:
            self.sessions[sid].from_app(frame["data"], frame.get('sentAt'), frame.get('maxAgeMs'))

    def watch(self):
        for session in list(self.sessions.values()):
            session.stop_stale(self.stop_after)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--relay", required=True, help="wss://<relay>/agent")
    p.add_argument("--rosbridge", default="ws://127.0.0.1:9090")
    p.add_argument("--token-file", help="file holding the robot token (else MOBILE_ROS_AGENT_TOKEN)")
    p.add_argument("--stop-after", type=float, default=0.5, help="seconds without a fresh velocity command")
    a = p.parse_args()
    if not 0.1 <= a.stop_after <= 2.0:
        p.error('--stop-after must be between 0.1 and 2.0 seconds')
    token = open(a.token_file).read().strip() if a.token_file else os.environ.get("MOBILE_ROS_AGENT_TOKEN", "")
    if not token:
        sys.exit("No robot token: set MOBILE_ROS_AGENT_TOKEN or --token-file.")
    if a.relay.startswith("ws://") and not a.relay.startswith(("ws://127.", "ws://localhost")):
        print("[agent] warning: ws:// is not encrypted; use wss:// over the internet", flush=True)
    ioloop.IOLoop.current().run_sync(Agent(a.relay, token, a.rosbridge, a.stop_after).run)


if __name__ == "__main__":
    main()
