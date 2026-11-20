#!/usr/bin/env python3
"""Print transform edges seen on each robot's TF topic (diagnosis and simulator readiness)."""
import sys
import rclpy
from tf2_msgs.msg import TFMessage
from rclpy.qos import QoSProfile, DurabilityPolicy

rclpy.init()
node = rclpy.create_node('mobile_ros_tf_check')
seen = {name: set() for name in sys.argv[1:] or ['robot1', 'robot2']}

for name in seen:
    def collect(msg, robot=name):
        for transform in msg.transforms:
            seen[robot].add((transform.header.frame_id, transform.child_frame_id))

    node.create_subscription(TFMessage, f'/{name}/tf', collect, 10)
    node.create_subscription(TFMessage, f'/{name}/tf_static', collect,
                             QoSProfile(depth=10, durability=DurabilityPolicy.TRANSIENT_LOCAL))

until = node.get_clock().now().nanoseconds + 5_000_000_000
while node.get_clock().now().nanoseconds < until:
    rclpy.spin_once(node, timeout_sec=0.2)

for name, edges in seen.items():
    print(f'{name}: {sorted(edges)}')
node.destroy_node()
rclpy.shutdown()
