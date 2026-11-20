import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/topic_discovery.dart' show TopicRole;
import 'support/fake_ros_connection.dart';

FakeConnection robot() => FakeConnection()
  ..serviceResponses.addAll({
    '/rosapi/topics': {
      'topics': ['/odom', '/robot1/odom', '/cmd_vel', '/map'],
      'types': ['nav_msgs/msg/Odometry', 'nav_msgs/msg/Odometry', 'geometry_msgs/msg/Twist',
        'nav_msgs/msg/OccupancyGrid'],
    },
    '/rosapi/action_servers': {'action_servers': ['/navigate_to_pose', '/arm/gripper_cmd']},
    '/rosapi/nodes': {'nodes': ['/bt_navigator', '/map_server']},
    // Nobody publishes: pick checks every candidate, then falls back to the best name.
    '/rosapi/publishers': {'publishers': []},
  });

void main() {
  test('discover reads topics, action servers, nodes and the ROS version', () async {
    final caps = await RobotCapabilities.discover(robot());
    expect(caps.topicNames, hasLength(4));
    expect(caps.actionServers, ['/navigate_to_pose', '/arm/gripper_cmd']);
    expect(caps.nodes, contains('/map_server'));
    expect(caps.rosVersion, RosVersion.ros2);
    expect(caps.topicsOfType('nav_msgs/Odometry'), ['/odom', '/robot1/odom']);
    expect(caps.actionNamed('navigate_to_pose'), '/navigate_to_pose');
    expect(caps.actionNamed('gripper_cmd'), '/arm/gripper_cmd');
    expect(caps.actionNamed('missing'), isNull);
  });

  test('a robot without rosapi gives empty capabilities instead of an error', () async {
    final caps = await RobotCapabilities.discover(_NoRosapi());
    expect(caps.topics, isNull);
    expect(caps.actionServers, isEmpty);
    expect(caps.nodes, isEmpty);
    expect(caps.rosVersion, RosVersion.ros2);
    expect(await caps.pick('nav_msgs/Odometry', 'odom'), isNull);
  });

  test('pick answers the same question once', () async {
    final connection = robot();
    final caps = await RobotCapabilities.discover(connection);
    int publisherChecks() => connection.calls.where((c) => c.$1 == '/rosapi/publishers').length;

    final first = await caps.pick('nav_msgs/Odometry', 'odom');
    final checks = publisherChecks();
    expect(checks, greaterThan(0));
    expect(await caps.pick('nav_msgs/Odometry', 'odom'), first);
    expect(publisherChecks(), checks, reason: 'the second screen reuses the answer');

    // Writing is a different question (subscribers, not publishers).
    expect(await caps.pick('geometry_msgs/Twist', 'cmd_vel', role: TopicRole.write), '/cmd_vel');
  });

  group('RobotSession', () {
    int discoveries(FakeConnection c) => c.calls.where((x) => x.$1 == '/rosapi/topics').length;

    test('screens opened together share one discovery', () async {
      final connection = robot();
      final session = RobotSession(connection: connection, ip: 'robot', port: '9090');
      final results = await Future.wait([session.capabilities(), session.capabilities()]);
      expect(identical(results[0], results[1]), isTrue);
      expect(discoveries(connection), 1);
    });

    test('discovers again after maxAge or invalidate', () async {
      final connection = robot();
      final session = RobotSession(connection: connection, ip: 'robot', port: '9090', maxAge: Duration.zero);
      await session.capabilities();
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await session.capabilities();
      expect(discoveries(connection), 2);

      final cached = RobotSession(connection: connection, ip: 'robot', port: '9090');
      await cached.capabilities();
      await cached.capabilities();
      expect(discoveries(connection), 3);
      cached.invalidate();
      await cached.capabilities();
      expect(discoveries(connection), 4);
    });
  });
}

class _NoRosapi extends FakeConnection {
  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    calls.add((service, args));
    throw StateError('rosapi is not running');
  }
}
