// ignore_for_file: avoid_print -- progress output is the point of this manual check
// First check after building: the app's connection against any rosbridge robot — the fake one is enough:
//   pip install websockets && python scripts/fake_robot.py --port 9091
//   flutter test tool/live_quickstart_test.dart --dart-define=PORT=9091
// Lists topics, reads odometry, drives 1 s forward and sees the odometry change, then stops.
import 'package:flutter_test/flutter_test.dart';
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
    final topics = List<String>.from((await connection.call('/rosapi/topics'))['topics'] as List);
    print('connected to $host:$port, ${topics.length} topics: ${topics.take(12).join(', ')}');
    expect(topics, contains('/odom'));

    double? x;
    final odom = ros.subscribe('/odom').listen((m) => x = ((m['pose'] as Map)['pose'] as Map)['position']['x'] as double?);
    addTearDown(odom.cancel);
    for (var i = 0; i < 50 && x == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(x, isNotNull, reason: 'odometry arrives');
    final start = x!;
    print('odometry x = ${start.toStringAsFixed(2)} m');

    final cmd = ros.advertise('/cmd_vel', 'geometry_msgs/msg/Twist');
    Map<String, Object> twist(double v) =>
        {'linear': {'x': v, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}};
    for (var i = 0; i < 10; i++) {
      cmd.publish(twist(0.2));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    cmd.publish(twist(0));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    print('after 1 s at 0.2 m/s: x = ${x!.toStringAsFixed(2)} m');
    expect(x! - start, greaterThan(0.05), reason: 'the robot moved forward');
  });
}
