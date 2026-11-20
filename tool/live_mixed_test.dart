// ignore_for_file: avoid_print
// Two different kinds of robot on one connection: a TurtleBot3 with Nav2 (/robot1) and a fixed arm
// (/arm1). Each must be described as what it is and given only its own skills, and commands for one
// must not reach the other.
//   DISTRO=humble SIM_SCRIPT=scripts/ros2_mixed_sim.sh bash scripts/dev-env/sim_live_test.sh tool/live_mixed_test.dart
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/robot_summary.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

class Scripted extends AgentBackend {
  List<SkillCall> next = const [];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: next);
}

void main() {
  late RosConnection connection;
  late RobotSession base, arm;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    final robots = (await RobotCapabilities.discover(connection)).robotNamespaces();
    print('  robots found: $robots');
    expect(robots, ['/arm1', '/robot1']);
    base = RobotSession(connection: connection, ip: host, port: port, namespace: '/robot1');
    arm = RobotSession(connection: connection, ip: host, port: port, namespace: '/arm1');
    await base.prepare();
    await arm.prepare();
    await base.odometry.waitFresh();
  });

  tearDownAll(() {
    base.dispose();
    arm.dispose();
    connection.close();
  });

  test('each robot is described as what it is, with its own skills', () async {
    final b = RobotSummary.from(await base.capabilities(), profile: base.drive.profile);
    final a = RobotSummary.from(await arm.capabilities(), profile: arm.drive.profile);
    final baseAgent = RobotAgent.forSession(base, Scripted()), armAgent = RobotAgent.forSession(arm, Scripted());
    final baseSkills = [for (final s in baseAgent.manifest().skills) s.name];
    final armSkills = [for (final s in armAgent.manifest().skills) s.name];
    print('  robot1: ${b.kind}; ${[for (final f in b.features) if (f.detected) f.label].join(', ')}');
    print('          skills: ${baseSkills.join(', ')}');
    print('  arm1:   ${a.kind}; ${[for (final f in a.features) if (f.detected) '${f.label} ${f.topics}'].join(', ')}');
    print('          skills: ${armSkills.join(', ')}');
    expect(b.kind, 'Mobile robot (turns in place)');
    expect(b.feature('drive')!.topics, ['/robot1/cmd_vel']);
    expect(b.has('navigation'), isTrue);
    expect(b.has('arm'), isFalse, reason: 'the arm belongs to the other robot');
    expect(a.kind, 'Robot arm');
    expect(a.feature('arm')!.topics.first, '/arm1/arm_controller/joint_trajectory');
    expect(a.has('drive'), isFalse);
    expect(a.has('navigation'), isFalse);
    expect(a.has('lidar'), isFalse, reason: 'the lidar belongs to the other robot');
    expect(baseSkills, containsAll(['move', 'rotate', 'navigate_to']));
    for (final skill in ['move', 'rotate', 'strafe', 'navigate_to']) {
      expect(armSkills, isNot(contains(skill)), reason: 'a fixed arm does not drive');
    }
    baseAgent.dispose();
    armAgent.dispose();
  });

  test('a drive command given to the arm is refused and moves nothing; the base still drives', () async {
    final backend = Scripted();
    final armAgent = RobotAgent.forSession(arm, backend);
    final start = base.odometry.pose!;
    backend.next = [const SkillCall('move', {'distance_m': 0.5})];
    final refused = await armAgent.handle('arm: forward');
    await Future<void>.delayed(const Duration(seconds: 1));
    final drift = math.sqrt(math.pow(base.odometry.pose!.x - start.x, 2) + math.pow(base.odometry.pose!.y - start.y, 2));
    print('  arm1 move -> ${refused.results.lastOrNull}; robot1 moved ${drift.toStringAsFixed(3)} m');
    expect(refused.ok, isFalse);
    expect(drift, lessThan(0.01));
    armAgent.dispose();

    final baseBackend = Scripted()..next = [const SkillCall('move', {'distance_m': 0.3})];
    final baseAgent = RobotAgent.forSession(base, baseBackend);
    final run = await baseAgent.handle('base: forward');
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final moved = math.sqrt(math.pow(base.odometry.pose!.x - start.x, 2) + math.pow(base.odometry.pose!.y - start.y, 2));
    print('  robot1 move -> ${run.results.lastOrNull}; odometry ${moved.toStringAsFixed(3)} m');
    expect(run.ok, isTrue);
    expect(moved, closeTo(0.3, 0.05));
    baseAgent.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
