import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/arm.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/robot_profile.dart';

const urdf = '''
<robot name="tb3_manipulator">
  <joint name="wheel_left_joint" type="continuous"><limit effort="1" velocity="1"/></joint>
  <joint name="joint1" type="revolute">
    <parent link="link1"/><child link="link2"/>
    <limit velocity="4.8" effort="1" lower="-2.827" upper="2.827" />
  </joint>
  <joint name="joint2" type="revolute"><limit lower="-1.79" upper="1.57" effort="1" velocity="4.8"/></joint>
  <joint name="gripper_left_joint" type="prismatic"><limit lower="-0.010" upper="0.019" effort="1" velocity="4.8"/></joint>
  <joint name="fixed_cam" type="fixed"/>
</robot>
''';

void main() {
  test('URDF limits are read for revolute and prismatic joints only', () {
    final limits = parseJointLimits(urdf);
    expect(limits.keys, unorderedEquals(['joint1', 'joint2', 'gripper_left_joint']));
    expect(limits['joint1']!.lower, -2.827);
    expect(limits['joint2']!.upper, 1.57);
    expect(limits['joint1']!.clamp(5), 2.827);
  });

  test('arm joints exclude wheels and grippers unless pinned', () {
    const names = ['wheel_left_joint', 'joint1', 'joint2', 'gripper_left_joint', 'wheel_right_joint'];
    expect(armJoints(names), ['joint1', 'joint2']);
    expect(armJoints(names, pinned: ['joint2']), ['joint2']);
    expect(gripperJoint(names), 'gripper_left_joint');
    expect(gripperJoint(['joint1']), isNull);
    // ros2_control publishes joint_states in arbitrary order; the URDF order (base -> tip) wins.
    const scrambled = ['wheel_right_joint', 'joint2', 'joint1', 'joint4', 'gripper_left_joint', 'joint3'];
    expect(armJoints(scrambled), ['joint2', 'joint1', 'joint4', 'joint3']);
    expect(armJoints(scrambled, urdfOrder: ['joint1', 'joint2', 'joint3', 'joint4']),
        ['joint1', 'joint2', 'joint3', 'joint4']);
    expect(armJoints(['extra', 'joint2', 'joint1'], urdfOrder: ['joint1', 'joint2']), ['joint1', 'joint2', 'extra']);
  });

  test('arm suggestion prefers an arm trajectory topic and finds the gripper action', () {
    final topics = {
      'topics': ['/head_controller/joint_trajectory', '/arm_controller/joint_trajectory', '/cmd_vel'],
      'types': ['trajectory_msgs/msg/JointTrajectory', 'trajectory_msgs/msg/JointTrajectory', 'geometry_msgs/msg/Twist'],
    };
    final arm = suggestArm(topics, ['/navigate_to_pose', '/gripper_controller/gripper_cmd'])!;
    expect(arm.trajectoryTopic, '/arm_controller/joint_trajectory');
    expect(arm.gripperAction, '/gripper_controller/gripper_cmd');
    expect(suggestArm({'topics': ['/cmd_vel'], 'types': ['geometry_msgs/Twist']}, const []), isNull);

    final mobile = suggestProfile(topics, actionServers: ['/gripper_controller/gripper_cmd']);
    expect(mobile.drive, DriveType.differential);
    expect(mobile.arm, isNotNull);
    final fixed = suggestProfile({'topics': ['/arm_controller/joint_trajectory'],
      'types': ['trajectory_msgs/msg/JointTrajectory']});
    expect(fixed.drive, DriveType.none, reason: 'an arm without a Twist topic has no base');
    expect(fixed.hasBase, isFalse);
  });

  test('trajectory and hold messages per ROS version', () {
    final msg = trajectoryMessage(['joint1', 'joint2'], [0.5, -0.25], 1.75, RosVersion.ros2);
    expect(msg['joint_names'], ['joint1', 'joint2']);
    expect(msg['points'][0]['positions'], [0.5, -0.25]);
    expect(msg['points'][0]['time_from_start'], {'sec': 1, 'nanosec': 750000000});
    expect(msg['header']['stamp'], {'sec': 0, 'nanosec': 0});
    final ros1 = trajectoryMessage(['j'], [0], 0.5, RosVersion.ros1);
    expect(ros1['points'][0]['time_from_start'], {'secs': 0, 'nsecs': 500000000});
    final hold = holdMessage(['joint1', 'joint2'], [0.7, -0.1], RosVersion.ros2);
    expect(hold['points'], hasLength(1), reason: 'Humble JTC rejects empty trajectories');
    expect(hold['points'][0]['positions'], [0.7, -0.1]);
    expect(hold['points'][0]['time_from_start'], {'sec': 0, 'nanosec': 200000000});
  });

  test('move duration follows the largest joint change with a floor', () {
    expect(moveDuration([0, 0], [1.0, 0.2], 0.5), 2.0);
    expect(moveDuration([0], [0.01], 1.0), 0.25);
  });

  test('profiles keep the arm through JSON', () {
    final p = RobotProfile.defaults(DriveType.differential,
        arm: const ArmConfig(trajectoryTopic: '/arm_controller/joint_trajectory', gripperAction: '/g'));
    final back = RobotProfile.fromJson(p.toJson())!;
    expect(back.arm!.trajectoryTopic, '/arm_controller/joint_trajectory');
    expect(back.arm!.gripperAction, '/g');
    expect(back.copyWith(clearArm: true).arm, isNull);
  });
}
