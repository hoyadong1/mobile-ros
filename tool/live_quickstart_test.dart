// ignore_for_file: avoid_print -- progress output is the point of this manual check
// First check after building: the app's connection against any rosbridge robot — the fake one is enough:
//   pip install websockets && python scripts/fake_robot.py --port 9091
//   flutter test tool/live_quickstart_test.dart --dart-define=PORT=9091
// Lists topics, reads odometry, drives 1 s forward and sees the odometry change, then stops.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('PORT', defaultValue: '9090');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect, list, read odometry, drive and stop', () async {
    final connection = RosConnection(host, port);
    addTearDown(connection.close);
    await connection.ready;
    final ros = RosClient(connection);
    final listed = await connection.call('/rosapi/topics');
    final topics = List<String>.from(listed['topics'] as List);
    final types = List<String>.from(listed['types'] as List);
    // Newer Nav2 / ros2_control robots take TwistStamped on /cmd_vel.
    final stamped = isTwistStamped(types[topics.indexOf('/cmd_vel')]);
    print('connected to $host:$port, ${topics.length} topics: ${topics.take(12).join(', ')}');
    expect(topics, contains('/odom'));

    double? x, y;
    final odom = ros.subscribe('/odom').listen((m) {
      final p = ((m['pose'] as Map)['pose'] as Map)['position'] as Map;
      x = (p['x'] as num).toDouble();
      y = (p['y'] as num).toDouble();
    });
    addTearDown(odom.cancel);
    for (var i = 0; i < 50 && x == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(x, isNotNull, reason: 'odometry arrives');
    final (x0, y0) = (x!, y!);
    print('odometry at (${x0.toStringAsFixed(2)}, ${y0.toStringAsFixed(2)})');

    print('/cmd_vel takes ${stamped ? 'TwistStamped' : 'Twist'}');
    final cmd = ros.advertise('/cmd_vel', stamped ? 'geometry_msgs/msg/TwistStamped' : 'geometry_msgs/msg/Twist');
    final profile = RobotProfile.defaults(DriveType.differential);
    Map<String, dynamic> twist(double v) =>
        commandMessage(profile, DriveCommand(linearX: v), RosVersion.ros2, stamped: stamped);
    for (var i = 0; i < 10; i++) {
      cmd.publish(twist(0.2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    cmd.publish(twist(0));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    // Forward is the robot's heading, not the odometry x axis: measure the distance covered.
    final moved = math.sqrt(math.pow(x! - x0, 2) + math.pow(y! - y0, 2));
    print('after 1 s at 0.2 m/s: moved ${moved.toStringAsFixed(2)} m');
    expect(moved, greaterThan(0.05), reason: 'the robot moved');
  });
}
