#!/usr/bin/env python3
"""Ask the person holding the Mobile ROS app a question, or notify them, from a ROS 2 robot.

The app listens on plain std_msgs/String topics carrying JSON (see lib/robot_requests.dart), so the
robot needs nothing beyond rclpy and std_msgs. Works whichever way the app is connected (rosbridge,
DDS, Zenoh).

In a node:
    from mobile_ros_phone import Phone
    phone = Phone(node)
    future = phone.ask("Door", "May I open the door?", ["Open", "Wait"], timeout=60)
    ...                        # keep spinning; future.result() -> "Open" / "Wait" / None (no answer)
    phone.notify("Battery", "20% left", level="warning")

From a shell (ROS 2 sourced):
    python3 mobile_ros_phone.py ask "Door" "May I open the door?" Open Wait     # prints the choice
    python3 mobile_ros_phone.py notify "Battery" "20% left" --level warning

Anyone on the robot's network can publish these topics, so the app only ever shows them; never act on
an answer for something dangerous without the robot's own safety checks.
"""
import argparse
import json
import sys
import uuid

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from rclpy.task import Future
from std_msgs.msg import String

ASK = "/mobile_ros/ask"
ANSWER = "/mobile_ros/answer"
NOTIFY = "/mobile_ros/notify"
REPEAT_S = 2.0  # the question is repeated until answered, in case the app missed it


class Phone:
    def __init__(self, node: Node, namespace: str = ""):
        """`namespace` is the robot's, e.g. "/robot1" when several robots share the network; the app
        shows the question as coming from that robot."""
        self.node = node
        ns = namespace.rstrip("/")
        qos = QoSProfile(depth=10, reliability=ReliabilityPolicy.RELIABLE)
        self._ask = node.create_publisher(String, ns + ASK, qos)
        self._notify = node.create_publisher(String, ns + NOTIFY, qos)
        node.create_subscription(String, ns + ANSWER, self._on_answer, qos)
        self._waiting = {}  # id -> (future, question, deadline, timer)

    def ask(self, title, message, options, timeout=60.0, urgent=False) -> Future:
        """Shows a question with answer buttons. The future resolves to the chosen option, or None when
        the person dismissed it or nobody answered within `timeout` seconds."""
        rid = uuid.uuid4().hex[:12]
        question = {"id": rid, "title": title, "message": message, "options": list(options),
                    "timeout_s": timeout, "urgent": urgent}
        future = Future()
        deadline = self.node.get_clock().now().nanoseconds + int(timeout * 1e9)
        timer = self.node.create_timer(REPEAT_S, lambda: self._repeat(rid))
        self._waiting[rid] = (future, question, deadline, timer)
        self._publish(self._ask, question)
        return future

    def cancel(self, future: Future):
        """Withdraws a question that is no longer needed (the app closes it)."""
        for rid, (f, *_rest) in list(self._waiting.items()):
            if f is future:
                self._finish(rid, None, withdraw=True)

    def listeners(self) -> int:
        """How many apps are listening for notices (0 means a notice now would reach no one)."""
        return self._notify.get_subscription_count()

    def notify(self, title, message="", level="info"):
        self._publish(self._notify, {"title": title, "message": message, "level": level})

    def _repeat(self, rid):
        entry = self._waiting.get(rid)
        if entry is None:
            return
        _, question, deadline, _ = entry
        if self.node.get_clock().now().nanoseconds > deadline:
            self._finish(rid, None, withdraw=True)
        else:
            self._publish(self._ask, question)

    def _on_answer(self, msg):
        try:
            answer = json.loads(msg.data)
        except ValueError:
            return
        rid = answer.get("id") if isinstance(answer, dict) else None
        if rid in self._waiting:
            self._finish(rid, None if answer.get("dismissed") else answer.get("choice"))

    def _finish(self, rid, choice, withdraw=False):
        future, _, _, timer = self._waiting.pop(rid)
        timer.cancel()
        self.node.destroy_timer(timer)
        if withdraw:
            self._publish(self._ask, {"id": rid, "cancel": True})
        if not future.done():
            future.set_result(choice)

    @staticmethod
    def _publish(pub, payload):
        pub.publish(String(data=json.dumps(payload, ensure_ascii=False)))


def main():
    parser = argparse.ArgumentParser(description="Ask or notify the Mobile ROS app.")
    parser.add_argument("--namespace", default="", help="the robot's namespace, e.g. /robot1")
    sub = parser.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("ask")
    a.add_argument("title")
    a.add_argument("message")
    a.add_argument("options", nargs="*", default=["OK"])
    a.add_argument("--timeout", type=float, default=60.0)
    a.add_argument("--urgent", action="store_true")
    n = sub.add_parser("notify")
    n.add_argument("title")
    n.add_argument("message", nargs="?", default="")
    n.add_argument("--level", choices=["info", "warning", "error"], default="info")
    args = parser.parse_args()

    rclpy.init()
    node = rclpy.create_node("mobile_ros_phone")
    phone = Phone(node, args.namespace)
    try:
        if args.cmd == "notify":
            # A notice is sent once, so wait until the app's subscription is matched (up to 10 s): on a busy
            # network discovery can take longer than a fixed pause, and the notice was then lost.
            for _ in range(100):
                if phone.listeners() > 0:
                    break
                rclpy.spin_once(node, timeout_sec=0.1)
            phone.notify(args.title, args.message, args.level)
            rclpy.spin_until_future_complete(node, Future(), timeout_sec=1.0)
            return 0
        future = phone.ask(args.title, args.message, args.options, args.timeout, args.urgent)
        rclpy.spin_until_future_complete(node, future, timeout_sec=args.timeout + 5)
        choice = future.result() if future.done() else None
        print(choice if choice is not None else "(no answer)", flush=True)
        return 0 if choice is not None else 1
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    sys.exit(main())
