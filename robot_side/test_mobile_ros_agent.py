"""Agent regression tests; no robot or tokens required. Run with Python + tornado."""
import asyncio
import json
import time
import unittest
from unittest.mock import patch

from mobile_ros_agent import Agent, Session


class Local:
    def __init__(self):
        self.messages = []
        self.closed = False

    def write_message(self, text):
        self.messages.append(json.loads(text))

    def close(self):
        self.closed = True


class SessionTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.agent = Agent('ws://localhost/agent', 'test-only', 'ws://localhost:9090', .5)
        self.frames = []
        self.agent.send = self.frames.append
        self.session = Session(self.agent, 'test', 'operator')

    def send(self, **m):
        self.session.from_app(json.dumps(m))

    def moving(self):
        self.send(op='advertise', topic='/cmd_vel', type='geometry_msgs/msg/Twist')
        self.send(op='publish', topic='/cmd_vel', msg={'linear': {'x': .2}, 'angular': {}})

    async def test_startup_never_replays_delayed_motion(self):
        self.moving()
        self.send(op='call_service', service='/rosapi/topics', id='discovery')
        self.send(op='send_action_goal', action='/navigate_to_pose')
        self.send(op='call_service', service='/rosapi/set_param', id='write')
        self.assertEqual([json.loads(m)['op'] for m in self.session.pending], ['advertise', 'call_service'])
        self.assertFalse(self.session.moving)
        self.assertTrue(any(json.loads(f['data']).get('result') is False for f in self.frames))

    async def test_watchdog_then_disconnect_publish_zero(self):
        self.session.local = Local()
        self.moving()
        self.session.moving['/cmd_vel'] = time.monotonic() - 1
        self.session.stop_stale(.5)
        self.assertEqual(self.session.local.messages[-1]['msg']['linear']['x'], 0)
        self.moving()
        self.session.close()
        self.assertEqual(self.session.local.messages[-1]['msg']['linear']['x'], 0)
        self.assertTrue(self.session.local.closed)
        count = len(self.session.local.messages)
        self.moving()
        self.assertEqual(len(self.session.local.messages), count, 'closed session cannot drive')

    async def test_close_during_local_handshake_does_not_open_an_orphan(self):
        connected = asyncio.Future()
        local = Local()
        with patch('mobile_ros_agent.websocket_connect', return_value=connected):
            task = asyncio.create_task(self.session.open())
            await asyncio.sleep(0)
            self.session.close()
            connected.set_result(local)
            await task
        self.assertTrue(local.closed)
        self.assertFalse(local.messages)

    async def test_disconnect_cancels_the_sessions_own_action_goals(self):
        self.session.local = Local()
        self.send(op='send_action_goal', id='goal-1', action='/navigate_to_pose', args={})
        self.session.close()
        self.assertEqual(self.session.local.messages[-1], {
            'op': 'cancel_action_goal', 'id': 'goal-1', 'action': '/navigate_to_pose'})
        self.assertFalse(self.session.actions)

    async def test_pending_messages_are_bounded_and_malformed_frames_ignored(self):
        for _ in range(257):
            self.send(op='subscribe', topic='/odom')
        self.assertTrue(self.session.closed)
        self.assertFalse(self.session.pending)
        self.agent.on_frame('null')
        self.agent.on_frame('[]')
        self.session.from_app('[]')

    async def test_expired_cloud_command_stops_and_is_never_replayed(self):
        self.session.local = Local()
        self.moving()
        self.session.from_app(json.dumps({'op': 'publish', 'topic': '/cmd_vel',
            'msg': {'linear': {'x': .2}, 'angular': {}}}), time.time() * 1000 - 2000, 500)
        self.assertTrue(self.session.closed)
        self.assertEqual(self.session.local.messages[-1]['msg']['linear']['x'], 0)
        self.assertTrue(any(frame.get('close') for frame in self.frames))


if __name__ == '__main__':
    unittest.main()
