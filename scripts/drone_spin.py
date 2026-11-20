#!/usr/bin/env python3
"""Takes off the PX4 SITL drone (scripts/ros2_drone_sim.sh), spins it in place at YAW_RATE rad/s in
OFFBOARD for SECONDS, then lands. Used to check the app's IMU readout against real rotation.
   python3 scripts/drone_spin.py [yaw_rate=0.5] [seconds=25]"""
import sys
import time
import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from geometry_msgs.msg import Twist
from mavros_msgs.msg import State
from mavros_msgs.srv import CommandBool, SetMode
from std_msgs.msg import Float64


def main():
    yaw_rate = float(sys.argv[1]) if len(sys.argv) > 1 else 0.5
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 25.0
    rclpy.init()
    node = Node('drone_spin')
    state = {'mode': '', 'armed': False, 'alt': 0.0}
    node.create_subscription(State, '/mavros/state',
                             lambda m: state.update(mode=m.mode, armed=m.armed), 10)
    node.create_subscription(Float64, '/mavros/global_position/rel_alt',
                             lambda m: state.update(alt=m.data), qos_profile_sensor_data)
    pub = node.create_publisher(Twist, '/mavros/setpoint_velocity/cmd_vel_unstamped', 10)
    arm = node.create_client(CommandBool, '/mavros/cmd/arming')
    mode = node.create_client(SetMode, '/mavros/set_mode')
    arm.wait_for_service()
    mode.wait_for_service()

    def spin_for(t, twist=None):
        end = time.time() + t
        while time.time() < end:
            if twist is not None:
                pub.publish(twist)
            rclpy.spin_once(node, timeout_sec=0.05)

    def call(client, req):
        future = client.call_async(req)
        rclpy.spin_until_future_complete(node, future, timeout_sec=5)

    call(mode, SetMode.Request(custom_mode='AUTO.TAKEOFF'))
    call(arm, CommandBool.Request(value=True))
    start = time.time()
    while state['alt'] < 2.0 and time.time() - start < 30:
        spin_for(0.2)
    print(f'airborne at {state["alt"]:.2f} m', flush=True)
    still, turn = Twist(), Twist()
    turn.angular.z = yaw_rate
    spin_for(1.0, still)  # OFFBOARD needs a setpoint stream before the switch
    call(mode, SetMode.Request(custom_mode='OFFBOARD'))
    spin_for(0.5, still)
    print(f'spinning at {yaw_rate} rad/s in {state["mode"]}', flush=True)
    spin_for(seconds, turn)
    spin_for(1.0, still)
    call(mode, SetMode.Request(custom_mode='AUTO.LAND'))
    print('landing', flush=True)
    spin_for(8.0)


if __name__ == '__main__':
    main()
