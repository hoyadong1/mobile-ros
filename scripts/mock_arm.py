#!/usr/bin/env python3
"""Minimal ROS 2 stand-in for a mobile manipulator, to exercise the app's arm controls when the
real simulation (turtlebot3_manipulation_gazebo) is not installed.

Behaves like a ros2_control JointTrajectoryController on /arm_controller/joint_trajectory:
  - follows each trajectory's last point linearly over its time_from_start
  - rejects trajectories whose joint_names differ from the controller joints (like JTC)
  - an empty trajectory is REJECTED, like the ROS 2 Humble JointTrajectoryController (newer versions
    treat it as "hold"); to stop, send a trajectory to the current position
Publishes /joint_states (30 Hz) and a latched /robot_description with joint limits, and accepts
/cmd_vel (logged) so the app sees a mobile base too. No gripper (needs control_msgs).

Run inside WSL with rosbridge:  python3 scripts/mock_arm.py   [--namespace /arm1] [--no-base]
"""
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy, ReliabilityPolicy
from geometry_msgs.msg import Twist
from sensor_msgs.msg import JointState
from std_msgs.msg import String
from trajectory_msgs.msg import JointTrajectory

ARM = ['joint1', 'joint2', 'joint3', 'joint4']
LIMITS = {'joint1': (-2.827, 2.827), 'joint2': (-1.79, 1.57), 'joint3': (-0.942, 1.382), 'joint4': (-1.79, 2.042)}
URDF = '<robot name="mock_manipulator">' + ''.join(
    f'<joint name="{j}" type="revolute"><limit lower="{lo}" upper="{hi}" effort="1" velocity="4.8"/></joint>'
    for j, (lo, hi) in LIMITS.items()) + \
    '<joint name="gripper_left_joint" type="prismatic"><limit lower="-0.010" upper="0.019" effort="1" velocity="4.8"/></joint>' \
    '<joint name="wheel_left_joint" type="continuous"/><joint name="wheel_right_joint" type="continuous"/></robot>'


class MockArm(Node):
    def __init__(self, ns='', base=True):
        super().__init__('mock_arm_controller')
        self.pos = {j: 0.0 for j in ARM}
        self.start, self.goal, self.t0, self.duration = dict(self.pos), dict(self.pos), 0.0, 0.0
        latched = QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL, reliability=ReliabilityPolicy.RELIABLE)
        self.create_publisher(String, ns + '/robot_description', latched).publish(String(data=URDF))
        self.states = self.create_publisher(JointState, ns + '/joint_states', 10)
        self.create_subscription(JointTrajectory, ns + '/arm_controller/joint_trajectory', self.on_trajectory, 10)
        if base:
            self.create_subscription(Twist, ns + '/cmd_vel', self.on_cmd_vel, 10)
        self.create_timer(1 / 30, self.tick)
        self.last_twist_log = 0.0
        self.get_logger().info('mock arm ready: /arm_controller/joint_trajectory, /joint_states, /cmd_vel')

    def now(self):
        return self.get_clock().now().nanoseconds / 1e9

    def on_trajectory(self, msg):
        if not msg.points:
            self.get_logger().error('REJECTED: empty trajectory (Humble JTC behaviour); arm keeps moving')
            return
        if list(msg.joint_names) != ARM:
            self.get_logger().error(f'REJECTED: joint_names {list(msg.joint_names)} != controller joints {ARM}')
            return
        last = msg.points[-1]
        t = last.time_from_start.sec + last.time_from_start.nanosec / 1e9
        goal = dict(zip(ARM, last.positions))
        bad = [j for j, v in goal.items() if not LIMITS[j][0] - 1e-6 <= v <= LIMITS[j][1] + 1e-6]
        if bad:
            self.get_logger().error(f'REJECTED: {bad} outside limits')
            return
        self.start, self.goal, self.t0, self.duration = dict(self.pos), goal, self.now(), max(t, 1e-3)
        self.get_logger().info(f'TRAJECTORY to {self.fmt(goal)} in {t:.2f}s')

    def on_cmd_vel(self, msg):
        if self.now() - self.last_twist_log > 0.5 and (msg.linear.x or msg.linear.y or msg.angular.z):
            self.get_logger().info(f'BASE cmd_vel x={msg.linear.x:+.2f} y={msg.linear.y:+.2f} yaw={msg.angular.z:+.2f}')
            self.last_twist_log = self.now()

    def tick(self):
        if self.duration > 0:
            a = min(1.0, (self.now() - self.t0) / self.duration)
            self.pos = {j: self.start[j] + (self.goal[j] - self.start[j]) * a for j in ARM}
            if a >= 1.0:
                self.duration = 0.0
        js = JointState()
        js.header.stamp = self.get_clock().now().to_msg()
        js.name = ['wheel_left_joint', 'wheel_right_joint'] + ARM + ['gripper_left_joint']
        js.position = [0.0, 0.0] + [self.pos[j] for j in ARM] + [0.0]
        self.states.publish(js)

    @staticmethod
    def fmt(p):
        return '[' + ', '.join(f'{p[j]:+.2f}' for j in ARM) + ']'


def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--namespace', default='', help='e.g. /arm1, to stand next to other robots')
    parser.add_argument('--no-base', action='store_true', help='a fixed arm: no /cmd_vel')
    args = parser.parse_args()
    rclpy.init()
    rclpy.spin(MockArm(args.namespace.rstrip('/'), not args.no_base))


if __name__ == '__main__':
    main()
