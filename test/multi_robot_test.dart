import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/robot_summary.dart';
import 'support/fake_ros_connection.dart';

/// What Nav2's two-TurtleBot3 simulation advertises (trimmed), plus a stray root /odom it really shows.
const twoRobots = {
  '/clock': 'rosgraph_msgs/msg/Clock',
  '/odom': 'nav_msgs/msg/Odometry',
  '/robot1/cmd_vel': 'geometry_msgs/msg/Twist',
  '/robot1/cmd_vel_nav': 'geometry_msgs/msg/Twist',
  '/robot1/odom': 'nav_msgs/msg/Odometry',
  '/robot1/map': 'nav_msgs/msg/OccupancyGrid',
  '/robot1/scan': 'sensor_msgs/msg/LaserScan',
  '/robot1/tf': 'tf2_msgs/msg/TFMessage',
  '/robot2/cmd_vel': 'geometry_msgs/msg/Twist',
  '/robot2/odom': 'nav_msgs/msg/Odometry',
  '/robot2/map': 'nav_msgs/msg/OccupancyGrid',
  '/robot2/scan': 'sensor_msgs/msg/LaserScan',
};

RobotCapabilities caps(Map<String, String> topics, {List<String> actions = const []}) => RobotCapabilities(
    connection: FakeConnection(), actionServers: actions,
    topics: {'topics': topics.keys.toList(), 'types': topics.values.toList()});

void main() {
  test('robots are found by namespace; a single robot at the root is the root', () {
    expect(caps(twoRobots).robotNamespaces(), ['/robot1', '/robot2'],
        reason: 'the stray /odom without /cmd_vel is not a robot');
    expect(caps({'/cmd_vel': 'geometry_msgs/msg/Twist', '/odom': 'nav_msgs/msg/Odometry'}).robotNamespaces(), ['']);
    expect(caps({
      '/arm1/arm_controller/joint_trajectory': 'trajectory_msgs/msg/JointTrajectory',
      '/arm1/joint_states': 'sensor_msgs/msg/JointState',
    }).robotNamespaces(), ['/arm1'], reason: 'an arm in a namespace');
    expect(caps({'/chatter': 'std_msgs/msg/String'}).robotNamespaces(), isEmpty);
  });

  test('scoping keeps a robot\'s own topics and the shared ones, never the other robot\'s', () {
    final all = caps(twoRobots, actions: ['/robot1/navigate_to_pose', '/robot2/navigate_to_pose']);
    final one = all.scoped('/robot1', all.robotNamespaces());
    expect(one.namespace, '/robot1');
    expect(one.topicNames, isNot(contains(startsWith('/robot2/'))));
    expect(one.topicNames, containsAll(['/robot1/cmd_vel', '/robot1/map', '/clock']));
    expect(one.actionNamed('navigate_to_pose'), '/robot1/navigate_to_pose');
    final summary = RobotSummary.from(one);
    expect(summary.feature('drive')!.topics, ['/robot1/cmd_vel']);
    expect(summary.feature('map')!.topics, ['/robot1/map']);
    expect(summary.feature('lidar')!.topics, ['/robot1/scan']);
  });

  test('with several robots, a robot is not credited with sensors outside its namespace', () {
    // Found with a TurtleBot3 (/robot1) and a fixed arm (/arm1): the simulator also publishes /scan and /odom
    // at the root, and the arm was shown as having a lidar.
    final all = caps({
      '/scan': 'sensor_msgs/msg/LaserScan',
      '/odom': 'nav_msgs/msg/Odometry',
      '/map': 'nav_msgs/msg/OccupancyGrid',
      '/robot1/cmd_vel': 'geometry_msgs/msg/Twist',
      '/robot1/odom': 'nav_msgs/msg/Odometry',
      '/robot1/scan': 'sensor_msgs/msg/LaserScan',
      '/arm1/arm_controller/joint_trajectory': 'trajectory_msgs/msg/JointTrajectory',
      '/arm1/joint_states': 'sensor_msgs/msg/JointState',
    });
    final robots = all.robotNamespaces();
    expect(robots, ['/arm1', '/robot1']);
    final arm = RobotSummary.from(all.scoped('/arm1', robots));
    expect(arm.kind, 'Robot arm');
    expect([for (final f in arm.features) if (f.detected) f.id], ['map', 'arm'], reason: 'the shared map only');
    final base = RobotSummary.from(all.scoped('/robot1', robots));
    expect(base.feature('lidar')!.topics, ['/robot1/scan']);
    expect(base.has('arm'), isFalse);
    // A robot alone on the connection keeps root topics: they can only be its own.
    final alone = caps({'/r/cmd_vel': 'geometry_msgs/msg/Twist', '/r/odom': 'nav_msgs/msg/Odometry',
      '/scan': 'sensor_msgs/msg/LaserScan'});
    expect(RobotSummary.from(alone.scoped('/r', alone.robotNamespaces())).has('lidar'), isTrue);
  });

  test('a session for /robot2 discovers only robot2 and saves per robot', () async {
    final robot = FakeConnection();
    robot.serviceResponses
      ..['/rosapi/topics'] = {'topics': twoRobots.keys.toList(), 'types': twoRobots.values.toList()}
      ..['/rosapi/action_servers'] = {'action_servers': ['/robot1/navigate_to_pose', '/robot2/navigate_to_pose']};
    final s = RobotSession(connection: robot, ip: 'pc', port: '9090', namespace: '/robot2');
    addTearDown(s.dispose);
    final c = await s.capabilities();
    expect(c.actionNamed('navigate_to_pose'), '/robot2/navigate_to_pose');
    expect(await c.pick('nav_msgs/Odometry', 'odom'), '/robot2/odom');
    expect(s.name, 'robot2');
    expect(s.storeAddress, 'pc:9090/robot2');
    expect(s.places.robot, 'pc:9090/robot2');
    expect(s.requests.namespace, '/robot2');
  });
}
