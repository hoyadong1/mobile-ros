#!/usr/bin/env python3
"""Republishes a topic under another name, to try the app's manual topic settings with a robot whose
topics have non-standard names:  python3 scripts/topic_relay.py /odom /wheel_state nav_msgs/msg/Odometry"""
import sys
import rclpy
from rclpy.node import Node
from rosidl_runtime_py.utilities import get_message


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    source, target, type_name = sys.argv[1:]
    rclpy.init()
    node = Node('topic_relay')
    msg_type = get_message(type_name)
    pub = node.create_publisher(msg_type, target, 10)
    node.create_subscription(msg_type, source, pub.publish, 10)
    node.get_logger().info(f'relaying {source} -> {target} ({type_name})')
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
