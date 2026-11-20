#!/usr/bin/env python3
"""Glue between the app and the gazebo_plugins demo vehicles used by scripts/ros2_vehicle_sim.sh.

- Always relays the demo odometry (/demo/odom_demo) to /odom, where real robots publish it, so the
  app's "ACTUAL" readout works.
- --mode ackermann: the app publishes ackermann_msgs/AckermannDriveStamped (speed + steering angle) on
  /ackermann_cmd, as real Ackermann stacks expect. gazebo_ros_ackermann_drive takes a Twist whose
  angular.z is the front-wheel steering angle itself (measured: 0.109 in -> 0.100 rad steer), not a yaw
  rate, so this passes speed and steering angle straight through.
  Like a real vehicle controller it stops when commands stop for 0.5 s.
"""
import argparse
import math

import rclpy
from rclpy.node import Node
from geometry_msgs.msg import Twist
from nav_msgs.msg import Odometry


class Bridge(Node):
    def __init__(self, mode, wheelbase):
        super().__init__('vehicle_bridge')
        self.odom = self.create_publisher(Odometry, '/odom', 10)
        self.create_subscription(Odometry, '/demo/odom_demo', self.odom.publish, 10)
        self.mode, self.wheelbase = mode, wheelbase
        if mode == 'ackermann':
            from ackermann_msgs.msg import AckermannDriveStamped
            self.cmd = self.create_publisher(Twist, '/demo/cmd_demo', 10)
            self.create_subscription(AckermannDriveStamped, '/ackermann_cmd', self.on_ackermann, 10)
            self.last = self.now()
            self.moving = False
            self.create_timer(0.1, self.watchdog)
        self.get_logger().info(f'vehicle bridge ready (mode={mode})')

    def now(self):
        return self.get_clock().now().nanoseconds / 1e9

    def on_ackermann(self, msg):
        speed, steer = msg.drive.speed, msg.drive.steering_angle
        twist = Twist()
        twist.linear.x = speed
        twist.angular.z = steer  # the plugin's convention: steering angle (rad), not yaw rate
        self.cmd.publish(twist)
        self.last = self.now()
        if (speed != 0) != self.moving:
            self.moving = speed != 0
            self.get_logger().info(f'ACKERMANN speed={speed:+.2f} m/s steer={math.degrees(steer):+.1f} deg')

    def watchdog(self):
        if self.moving and self.now() - self.last > 0.5:
            self.cmd.publish(Twist())
            self.moving = False
            self.get_logger().info('WATCHDOG: no /ackermann_cmd for 0.5 s -> stop')


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--mode', choices=['relay', 'ackermann'], default='relay')
    p.add_argument('--wheelbase', type=float, default=2.86)  # prius_hybrid in the demo world
    args, _ = p.parse_known_args()
    rclpy.init()
    rclpy.spin(Bridge(args.mode, args.wheelbase))


if __name__ == '__main__':
    main()
