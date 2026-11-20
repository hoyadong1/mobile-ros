#!/usr/bin/env python3
"""Stops the robot when velocity commands stop arriving (a dead-man for teleoperation).

A phone or a browser drives by publishing velocity commands. If its connection drops mid-motion it
cannot send "stop", and a base without a command timeout keeps executing the last command (measured on
a simulated TurtleBot3: still moving 4 s after the link was cut). This node watches the command topic
and, when a non-zero command is not followed by another within the timeout, publishes zero.

Run on the robot (ROS 2 sourced):
    python3 cmd_vel_watchdog.py                         # /cmd_vel, 0.5 s
    python3 cmd_vel_watchdog.py --topic /robot1/cmd_vel --timeout 0.3

Prefer the base's own timeout where it has one (ros2_control diff_drive_controller `cmd_vel_timeout`,
twist_mux timeouts); this is for bases that have none. It handles Twist and TwistStamped.
"""
import argparse
import sys

import rclpy
from geometry_msgs.msg import Twist, TwistStamped
from rclpy.node import Node


def is_zero(t: Twist) -> bool:
    return not any((t.linear.x, t.linear.y, t.linear.z, t.angular.x, t.angular.y, t.angular.z))


class Watchdog(Node):
    def __init__(self, topic: str, timeout: float):
        super().__init__("cmd_vel_watchdog")
        self.topic, self.timeout = topic, timeout
        self.stamped = None
        self.pub = None
        self.moving_since_ns = None  # time of the last non-zero command, None when at rest
        self.create_timer(0.2, self._find_type)
        self.create_timer(min(0.1, timeout / 2), self._check)

    def _find_type(self):
        if self.pub is not None:
            return
        types = dict(self.get_topic_names_and_types()).get(self.topic)
        if not types:
            return
        self.stamped = any("TwistStamped" in t for t in types)
        kind = TwistStamped if self.stamped else Twist
        self.pub = self.create_publisher(kind, self.topic, 10)
        self.create_subscription(kind, self.topic, self._on_command, 10)
        self.get_logger().info(f"watching {self.topic} ({kind.__name__}), timeout {self.timeout} s")

    def _on_command(self, msg):
        twist = msg.twist if self.stamped else msg
        self.moving_since_ns = None if is_zero(twist) else self.get_clock().now().nanoseconds

    def _check(self):
        if self.moving_since_ns is None or self.pub is None:
            return
        if self.get_clock().now().nanoseconds - self.moving_since_ns > self.timeout * 1e9:
            self.get_logger().warn(f"no command for {self.timeout} s while moving: stopping")
            stop = TwistStamped() if self.stamped else Twist()
            if self.stamped:
                stop.header.stamp = self.get_clock().now().to_msg()
            self.pub.publish(stop)  # arrives back as a zero command, which clears moving_since_ns


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--topic", default="/cmd_vel")
    parser.add_argument("--timeout", type=float, default=0.5, help="seconds without a command before stopping")
    args = parser.parse_args()
    rclpy.init()
    node = Watchdog(args.topic, args.timeout)
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == "__main__":
    sys.exit(main())
