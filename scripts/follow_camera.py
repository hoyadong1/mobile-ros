#!/usr/bin/env python3
"""Move Gazebo's demo camera behind the robot using its odometry."""
import math
import subprocess

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from nav_msgs.msg import Odometry


class FollowCamera(Node):
    def __init__(self):
        super().__init__('demo_camera_follow')
        self.pose = None
        self.process = None
        self.create_subscription(Odometry, '/odom', self.on_odom, qos_profile_sensor_data)
        self.create_timer(0.2, self.update)

    def on_odom(self, msg):
        self.pose = msg.pose.pose

    def update(self):
        if self.pose is None or (self.process is not None and self.process.poll() is None):
            return
        p, q = self.pose.position, self.pose.orientation
        yaw = math.atan2(2 * (q.w*q.z + q.x*q.y), 1 - 2 * (q.y*q.y + q.z*q.z))
        self.process = subprocess.Popen([
            'gz', 'model', '-m', 'demo_camera',
            '-x', str(p.x - 1.7 * math.cos(yaw)),
            '-y', str(p.y - 1.7 * math.sin(yaw)),
            '-z', str(p.z + 1.3), '-R', '0', '-P', '0.6', '-Y', str(yaw),
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    rclpy.init()
    node = FollowCamera()
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        if node.process is not None and node.process.poll() is None:
            node.process.terminate()
            node.process.wait(timeout=3)
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == '__main__':
    main()
