import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_summary.dart';
import 'support/fake_ros_connection.dart';

RobotCapabilities caps(Map<String, String> topics, {List<String> actions = const [], List<String> nodes = const []}) =>
    RobotCapabilities(connection: FakeConnection(), actionServers: actions, nodes: nodes,
        topics: {'topics': topics.keys.toList(), 'types': topics.values.toList()});

void main() {
  test('a TurtleBot3 with Nav2: what it is and what it has', () {
    final s = RobotSummary.from(caps({
      '/cmd_vel': 'geometry_msgs/msg/Twist',
      '/odom': 'nav_msgs/msg/Odometry',
      '/global_costmap/costmap': 'nav_msgs/msg/OccupancyGrid',
      '/map': 'nav_msgs/msg/OccupancyGrid',
      '/local_costmap/clearing_endpoints': 'sensor_msgs/msg/PointCloud2',
      '/scan': 'sensor_msgs/msg/LaserScan',
      '/imu': 'sensor_msgs/msg/Imu',
      '/camera/image_raw/compressed': 'sensor_msgs/msg/CompressedImage',
      '/camera/depth/image_raw': 'sensor_msgs/msg/Image',
      '/camera/image_raw/compressedDepth': 'sensor_msgs/msg/CompressedImage', // a transport, not a depth camera
    }, actions: ['/navigate_to_pose'], nodes: ['/turtlebot3_node', '/bt_navigator']));
    expect(s.model, 'TurtleBot3');
    expect(s.kind, 'Mobile robot (turns in place)');
    expect(s.rosVersion, RosVersion.ros2);
    expect([for (final f in s.features) if (f.detected) f.id],
        ['drive', 'odometry', 'map', 'navigation', 'lidar', 'camera', 'depth', 'imu']);
    expect(s.feature('camera')!.topics, ['/camera/image_raw/compressed'], reason: 'depth images are not the camera');
    expect(s.feature('map')!.topics, ['/map'], reason: 'costmaps are navigation working data, not the map');
    expect(s.feature('depth')!.topics, ['/camera/depth/image_raw']);
    expect(s.feature('battery')!.detected, isFalse, reason: 'not seen, so not claimed');
    expect(s.assistantCan, containsAll(['drive and turn', 'go to points and saved places on the map', 'look through the camera']));
    expect((s.topicCount, s.nodeCount, s.actionCount), (10, 2, 1));
  });

  test('an arm without a base, and a robot that does not describe itself', () {
    final arm = RobotSummary.from(caps({
      '/joint_states': 'sensor_msgs/msg/JointState',
      '/arm_controller/joint_trajectory': 'trajectory_msgs/msg/JointTrajectory',
    }, actions: ['/gripper_controller/gripper_cmd'], nodes: ['/ur_ros2_control_node']));
    expect(arm.kind, 'Robot arm');
    expect(arm.model, 'Universal Robots arm');
    expect(arm.feature('arm')!.topics, ['/arm_controller/joint_trajectory', '/gripper_controller/gripper_cmd']);
    expect(arm.has('drive'), isFalse);
    expect(arm.assistantCan, isNot(contains('drive and turn')));

    final silent = RobotSummary.from(RobotCapabilities(connection: FakeConnection()));
    expect(silent.discovered, isFalse);
  });

  test('a stored profile wins over the guess from topics', () {
    final s = RobotSummary.from(caps({'/cmd_vel': 'geometry_msgs/msg/Twist'}),
        profile: RobotProfile.defaults(DriveType.holonomic, commandTopic: '/cmd_vel'));
    expect(s.kind, 'Mobile robot (moves in any direction)');
  });
}
