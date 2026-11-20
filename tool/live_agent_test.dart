// Live end-to-end check of the AI agent path (skills → validator → controllers → ROS) against a running
// rosbridge robot, e.g. scripts/ros2_sim.sh or scripts/ros2_jazzy_sim.sh. A scripted backend stands in
// for the language model, so this measures what the robot actually does for each skill.
// Not part of `flutter test`; run explicitly:
//   flutter test tool/live_agent_test.dart --dart-define=ROBOT_HOST=127.0.0.1 --dart-define=ROBOT_PORT=9090
// ignore_for_file: avoid_print -- progress output is the point of this manual check
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/drone.dart' show yawOf;
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/robot_session.dart';

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

void main() {
  late RosConnection connection;
  late RobotSession session;
  late RosClient observer;
  ({double x, double y, double yaw})? odom;
  StreamSubscription<Map<String, dynamic>>? odomSub;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    observer = RosClient(RosConnection(host, port));
    await observer.connection.ready;
    odomSub = observer.subscribe('/odom', throttleRate: 50).listen((m) {
      final p = m['pose']['pose'];
      odom = (x: (p['position']['x'] as num).toDouble(), y: (p['position']['y'] as num).toDouble(),
          yaw: yawOf(p['orientation'] as Map));
    });
    await session.prepare();
    for (var i = 0; i < 50 && odom == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(odom, isNotNull, reason: 'odometry from the robot');
    print('drive: ${session.drive.profile?.drive.name} on ${session.drive.profile?.commandTopic}, '
        'navigation: ${session.nav.label}');
  });

  tearDownAll(() async {
    await odomSub?.cancel();
    session.dispose();
    connection.close();
    observer.connection.close();
  });

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 800));
  double angleDiff(double a, double b) => math.atan2(math.sin(a - b), math.cos(a - b));

  test('move 0.5 m forward (open loop)', () async {
    final before = odom!;
    final run = await RobotAgent.forSession(session,
        Scripted([const SkillCall('move', {'distance_m': 0.5})])).handle('앞으로 50센티');
    await settle();
    final after = odom!;
    final moved = math.sqrt(math.pow(after.x - before.x, 2) + math.pow(after.y - before.y, 2));
    print('move: ${run.results.map((r) => r.message).join(' / ')}; odometry says ${moved.toStringAsFixed(3)} m');
    expect(run.ok, isTrue);
    expect(moved, closeTo(0.5, 0.15));
  });

  test('rotate 90° left (open loop)', () async {
    final before = odom!;
    final run = await RobotAgent.forSession(session,
        Scripted([const SkillCall('rotate', {'angle_deg': 90})])).handle('왼쪽으로 90도');
    await settle();
    final turned = angleDiff(odom!.yaw, before.yaw) * 180 / math.pi;
    print('rotate: ${run.results.single.message}; odometry says ${turned.toStringAsFixed(1)}°');
    expect(run.ok, isTrue);
    expect(turned, closeTo(90, 20));
  });

  test('a stop word interrupts a long move', () async {
    final agent = RobotAgent.forSession(session, Scripted([const SkillCall('move', {'distance_m': 2.0})]));
    final before = odom!;
    final running = agent.handle('앞으로 2미터');
    await Future<void>.delayed(const Duration(seconds: 2));
    await agent.handle('멈춰');
    final run = await running;
    await settle();
    final moved = math.sqrt(math.pow(odom!.x - before.x, 2) + math.pow(odom!.y - before.y, 2));
    print('stop word: plan ended "${run.results.isEmpty ? run.error : run.results.last.message}", '
        'robot moved ${moved.toStringAsFixed(2)} m of 2.0');
    expect(run.ok, isFalse);
    expect(moved, lessThan(1.0));
  });

  test('navigate_to drives to a map point through Nav2', () async {
    final run = await RobotAgent.forSession(session,
        Scripted([const SkillCall('navigate_to', {'x': -0.5, 'y': -0.5})])).handle('(-0.5, -0.5)로 가');
    print('navigate_to: ${run.results.single.message}');
    expect(run.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
