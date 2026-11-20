// ignore_for_file: avoid_print
// What the app says about the simulated robot when it connects (TurtleBot3 + Nav2 in Gazebo).
//   FLUTTER=<flutter> DISTRO=jazzy bash scripts/dev-env/sim_live_test.sh tool/live_summary_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_summary.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

void main() {
  test('the simulated robot is described from what it advertises', () async {
    final connection = RosConnection(host, port);
    await connection.ready;
    addTearDown(connection.close);
    final s = RobotSummary.from(await RobotCapabilities.discover(connection));
    print('  ${[s.model, s.kind].whereType<String>().join(' · ')}  (${s.topicCount} topics, ${s.nodeCount} nodes, ${s.actionCount} actions)');
    for (final f in s.features) {
      print('  ${f.detected ? '[x]' : '[ ]'} ${f.label}${f.detected ? ': ${f.topics.take(3).join(', ')}' : ''}');
    }
    print('  AI can: ${s.assistantCan.join(', ')}');
    expect(s.discovered, isTrue);
    for (final id in ['drive', 'odometry', 'map', 'navigation', 'lidar', 'camera', 'imu']) {
      expect(s.has(id), isTrue, reason: id);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
