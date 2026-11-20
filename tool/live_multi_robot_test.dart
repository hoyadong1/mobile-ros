// ignore_for_file: avoid_print
// Two robots on one connection (Nav2's two-TurtleBot3 simulation, namespaces robot1/robot2): each gets
// its own session, and driving, navigating or asking on one never touches the other.
//   FLUTTER=<flutter> DISTRO=jazzy MULTI=1 bash scripts/dev-env/sim_live_test.sh tool/live_multi_robot_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/robot_summary.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

class Scripted extends AgentBackend {
  Scripted(this.calls);
  final List<SkillCall> calls;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls);
}

double dist(Pose2D a, Pose2D b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

Future<Process> robotHelper(List<String> args) {
  final repo = Directory.current.path.replaceAll(r'\', '/');
  final wslRepo = '/mnt/${repo[0].toLowerCase()}${repo.substring(2)}';
  final quoted = args.map((a) => "'${a.replaceAll("'", r"'\''")}'").join(' ');
  // The simulation's distro (sim_live_test.sh passes them; Jazzy by default).
  const distro = String.fromEnvironment('WSL_DISTRO', defaultValue: 'ros-jazzy');
  const ros = String.fromEnvironment('ROS_DISTRO', defaultValue: 'jazzy');
  return Process.start('wsl.exe', ['-d', distro, '--', 'bash', '-lc',
    'source /opt/ros/$ros/setup.bash && python3 $wslRepo/robot_side/mobile_ros_phone.py $quoted']);
}

void main() {
  late RosConnection connection;
  late RobotSession one, two;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    final robots = (await RobotCapabilities.discover(connection)).robotNamespaces();
    print('  robots: $robots');
    expect(robots, ['/robot1', '/robot2']);
    one = RobotSession(connection: connection, ip: host, port: port, namespace: '/robot1');
    two = RobotSession(connection: connection, ip: host, port: port, namespace: '/robot2');
    await one.prepare();
    await two.prepare();
    await one.odometry.waitFresh();
    await two.odometry.waitFresh();
  });

  tearDownAll(() {
    one.dispose();
    two.dispose();
    connection.close();
  });

  test('each robot is described with its own topics', () async {
    for (final s in [one, two]) {
      final summary = RobotSummary.from(await s.capabilities(), profile: s.drive.profile);
      final ns = s.namespace;
      print('  ${s.name}: ${summary.kind}; drive ${summary.feature('drive')!.topics}, '
          'nav ${summary.feature('navigation')!.topics}, map ${summary.feature('map')!.topics}');
      expect(summary.feature('drive')!.topics, ['$ns/cmd_vel']);
      expect(summary.feature('navigation')!.topics, ['$ns/navigate_to_pose']);
      expect(summary.feature('map')!.topics.first, '$ns/map');
      expect(s.odometry.topic, '$ns/odom');
    }
  });

  test('driving robot1 moves only robot1', () async {
    final start1 = one.odometry.pose!, start2 = two.odometry.pose!;
    final agent = RobotAgent.forSession(one, Scripted([const SkillCall('move', {'distance_m': 0.3})]));
    final run = await agent.handle('robot1 forward 30 cm');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final moved1 = dist(start1, one.odometry.pose!), moved2 = dist(start2, two.odometry.pose!);
    print('  robot1 moved ${moved1.toStringAsFixed(3)} m, robot2 moved ${moved2.toStringAsFixed(3)} m');
    expect(run.ok, isTrue);
    expect(moved1, closeTo(0.3, 0.03));
    expect(moved2, lessThan(0.01));
    agent.dispose();
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('robot2 navigates on its own while robot1 stays', () async {
    final start1 = one.odometry.pose!, start2 = two.odometry.pose!;
    final status = await two.nav.goTo(const Pose2D(0.6, -0.5, 0)).timeout(const Duration(minutes: 2));
    final moved1 = dist(start1, one.odometry.pose!), moved2 = dist(start2, two.odometry.pose!);
    print('  robot2 navigation: ${status.name}, robot2 moved ${moved2.toStringAsFixed(2)} m, robot1 ${moved1.toStringAsFixed(3)} m');
    expect(status, NavStatus.succeeded);
    expect(moved2, greaterThan(0.3));
    expect(moved1, lessThan(0.01));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a question from robot2 reaches robot2\'s listener only', () async {
    one.requests.start();
    two.requests.start();
    final helper = await robotHelper(['--namespace', '/robot2', 'ask', '도움', '길이 막혔어요', '돌아가', '기다려', '--timeout', '40']);
    final out = helper.stdout.transform(utf8.decoder).join();
    final end = DateTime.now().add(const Duration(seconds: 30));
    while (two.requests.pending.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(two.requests.pending, hasLength(1));
    expect(one.requests.pending, isEmpty);
    two.requests.answer(two.requests.pending.single.id, 1);
    expect(await helper.exitCode.timeout(const Duration(seconds: 20)), 0);
    print('  robot2 asked, the person answered: ${(await out).trim()}');
    expect((await out).trim(), '기다려');
  }, timeout: const Timeout(Duration(minutes: 1)));
}
