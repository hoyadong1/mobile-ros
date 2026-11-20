// ignore_for_file: avoid_print
// One check for every kind of robot: what the app says the robot is, which skills the AI assistant is
// given for it, and that those skills really move it (and the others are refused). Run through
// scripts/dev-env/sim_live_test.sh with the matching simulation:
//   KIND=diff   TurtleBot3 + Nav2            (default simulation, either distro)
//   KIND=car    SIM_SCRIPT="scripts/ros2_vehicle_sim.sh car"   DISTRO=humble
//   KIND=omni   SIM_SCRIPT="scripts/ros2_vehicle_sim.sh omni"  DISTRO=humble
//   KIND=arm    SIM_SCRIPT="scripts/ros2_arm_sim.sh"           DISTRO=humble
//   KIND=drone  SIM_SCRIPT="scripts/ros2_drone_sim.sh"         DISTRO=humble
// e.g. DEFINES="--dart-define=KIND=car"
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/robot_summary.dart';
import 'package:ros_tester/routines.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const kind = String.fromEnvironment('KIND', defaultValue: 'diff');

class Scripted extends AgentBackend {
  List<SkillCall> next = const [];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: next);
}

void main() {
  late RosConnection connection;
  late RobotSession session;
  late RobotAgent agent;
  final backend = Scripted();

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    await session.prepare();
    agent = RobotAgent.forSession(session, backend);
  });

  tearDownAll(() {
    agent.stop();
    session.dispose();
    connection.close();
  });

  Future<AgentRun> run(SkillCall call) {
    backend.next = [call];
    return agent.handle('$call');
  }

  /// Runs [call] and returns (run, distance moved, degrees turned, sideways share of the motion).
  Future<(AgentRun, double, double, Pose2D, Pose2D)> moved(SkillCall call) async {
    await session.odometry.waitFresh();
    final a = session.odometry.pose!;
    final r = await run(call);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final b = session.odometry.pose!;
    final d = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
    final turn = math.atan2(math.sin(b.yaw - a.yaw), math.cos(b.yaw - a.yaw)) * 180 / math.pi;
    print('  $call -> ${r.results.lastOrNull ?? r.error}; odometry: ${d.toStringAsFixed(3)} m, ${turn.toStringAsFixed(1)}°');
    return (r, d, turn, a, b);
  }

  test('what the app says this robot is, and the skills the assistant gets ($kind)', () async {
    final s = RobotSummary.from(await session.capabilities(), profile: session.drive.profile);
    final skills = agent.manifest().skills.map((k) => k.name).toList();
    print('  summary: ${[s.model, s.kind].whereType<String>().join(' · ')}');
    print('  detected: ${[for (final f in s.features) if (f.detected) '${f.label} ${f.topics.take(2).toList()}'].join('; ')}');
    print('  profile: ${session.drive.profile?.drive.name} on ${session.drive.profile?.commandTopic}; odom ${session.odometry.topic}');
    print('  skills: ${skills.join(', ')}');
    print('  describe: ${agent.manifest().describe()}');
    switch (kind) {
      case 'diff':
        expect(s.kind, 'Mobile robot (turns in place)');
        expect(skills, containsAll(['move', 'rotate']));
        expect(skills, isNot(contains('strafe')));
      case 'car':
        expect(s.kind, 'Mobile robot (car-like steering)');
        expect(skills, contains('move'));
        expect(skills, isNot(contains('rotate')), reason: 'a car cannot turn in place');
        expect(skills, isNot(contains('strafe')));
      case 'omni':
        // A Twist topic alone cannot tell omni from differential: the app suggests differential and the
        // person picks "Omnidirectional" in the robot settings. The next test does that.
        expect(s.has('drive'), isTrue);
      case 'arm':
        expect(s.has('arm'), isTrue);
        expect(s.kind, anyOf('Mobile manipulator (base + arm)', 'Robot arm'));
      case 'drone':
        expect(s.kind, 'Drone');
        expect(skills, isNot(contains('move')), reason: 'the assistant does not fly drones');
        expect(skills, isNot(contains('rotate')));
    }
  });

  test('the skills move the robot; skills it does not have are refused ($kind)', () async {
    switch (kind) {
      case 'diff':
        final (r1, d, _, _, _) = await moved(const SkillCall('move', {'distance_m': 0.3}));
        expect(r1.ok, isTrue);
        expect(d, closeTo(0.3, 0.05));
        final (r2, _, turn, _, _) = await moved(const SkillCall('rotate', {'angle_deg': -90}));
        expect(r2.ok, isTrue);
        expect(turn, closeTo(-90, 6));
        final (r3, d3, _, _, _) = await moved(const SkillCall('strafe', {'distance_m': 0.3}));
        expect(r3.ok, isFalse, reason: 'no sideways motion on this base');
        expect(d3, lessThan(0.02));
      case 'car':
        final (r1, d, _, _, _) = await moved(const SkillCall('move', {'distance_m': 1.0}));
        expect(r1.ok, isTrue);
        expect(d, closeTo(1.0, 0.25));
        final (r2, d2, turn, _, _) = await moved(const SkillCall('rotate', {'angle_deg': 90}));
        expect(r2.ok, isFalse, reason: 'refused before anything moves');
        expect(d2, lessThan(0.05));
        expect(turn.abs(), lessThan(3));
        final (r3, d3, _, _, _) = await moved(const SkillCall('move', {'distance_m': -0.5}));
        expect(r3.ok, isTrue);
        expect(d3, closeTo(0.5, 0.2));
      case 'omni':
        session.drive.configure(session.drive.profile!.copyWith(drive: DriveType.holonomic), (await session.capabilities()).rosVersion);
        expect(agent.manifest().skills.map((k) => k.name), containsAll(['move', 'strafe', 'rotate']));
        final (r1, d, _, _, _) = await moved(const SkillCall('move', {'distance_m': 0.3}));
        expect(r1.ok, isTrue);
        expect(d, closeTo(0.3, 0.05));
        final (r2, d2, turn2, a, b) = await moved(const SkillCall('strafe', {'distance_m': 0.3}));
        expect(r2.ok, isTrue);
        expect(d2, closeTo(0.3, 0.05));
        expect(turn2.abs(), lessThan(5), reason: 'sideways without turning');
        // Sideways means along the robot's left: project the motion on its heading.
        final forward = (b.x - a.x) * math.cos(a.yaw) + (b.y - a.y) * math.sin(a.yaw);
        final left = -(b.x - a.x) * math.sin(a.yaw) + (b.y - a.y) * math.cos(a.yaw);
        print('  strafe: ${left.toStringAsFixed(3)} m to the left, ${forward.toStringAsFixed(3)} m forward');
        expect(left, closeTo(0.3, 0.05));
        final (r3, _, turn3, _, _) = await moved(const SkillCall('rotate', {'angle_deg': 90}));
        expect(r3.ok, isTrue);
        expect(turn3, closeTo(90, 6));
      case 'arm':
        final skills = agent.manifest().skills.map((k) => k.name).toList();
        if (skills.contains('move')) {
          final (r1, d, _, _, _) = await moved(const SkillCall('move', {'distance_m': 0.2}));
          expect(r1.ok, isTrue);
          expect(d, closeTo(0.2, 0.05));
        }
        final status = await run(const SkillCall('get_status'));
        expect(status.ok, isTrue);
      case 'drone':
        final r = await run(const SkillCall('move', {'distance_m': 0.5}));
        print('  move -> ${r.results.lastOrNull}');
        expect(r.ok, isFalse, reason: 'refused: not a skill for drones');
        expect((await run(const SkillCall('get_status'))).ok, isTrue);
    }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a saved routine runs the robot steps, and stops at a step this robot lacks ($kind)', () async {
    final skills = agent.manifest().skills.map((k) => k.name).toSet();
    if (!skills.contains('move')) {
      print('  no move skill: routine with motion skipped');
      return;
    }
    final steps = [
      const RoutineStep.call(SkillCall('move', {'distance_m': 0.25})),
      if (skills.contains('rotate')) const RoutineStep.call(SkillCall('rotate', {'angle_deg': 45})),
      if (skills.contains('strafe')) const RoutineStep.call(SkillCall('strafe', {'distance_m': 0.2})),
      const RoutineStep.call(SkillCall('move', {'distance_m': -0.25})),
    ];
    await session.routines.load();
    final routine = await session.routines.save(Routine(id: 'r1', name: 'check', steps: steps));
    await session.odometry.waitFresh();
    final a = session.odometry.pose!;
    final done = await agent.runRoutine(routine);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final b = session.odometry.pose!;
    final turn = math.atan2(math.sin(b.yaw - a.yaw), math.cos(b.yaw - a.yaw)) * 180 / math.pi;
    print('  routine (${steps.length} steps): ${done.results.lastOrNull ?? done.error}; turned ${turn.toStringAsFixed(0)}°');
    expect(done.ok, isTrue);
    if (skills.contains('rotate')) expect(turn, closeTo(45, 8));

    // A routine made on another robot may hold a step this one cannot do: it stops there, before moving.
    if (skills.contains('rotate') && skills.contains('strafe')) return;
    final foreign = await session.routines.save(Routine(id: 'r2', name: 'foreign', steps: [
      if (!skills.contains('rotate'))
        const RoutineStep.call(SkillCall('rotate', {'angle_deg': 90}))
      else
        const RoutineStep.call(SkillCall('strafe', {'distance_m': 0.3})),
      const RoutineStep.call(SkillCall('move', {'distance_m': 0.3})),
    ]));
    final c = session.odometry.pose!;
    final refused = await agent.runRoutine(foreign);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final d = session.odometry.pose!;
    final shift = math.sqrt(math.pow(d.x - c.x, 2) + math.pow(d.y - c.y, 2));
    print('  foreign routine: ${refused.results.lastOrNull}; moved ${shift.toStringAsFixed(3)} m');
    expect(refused.ok, isFalse);
    expect(shift, lessThan(0.02), reason: 'the step after the refused one did not run');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a stop word halts a long move at once ($kind)', () async {
    if (!agent.manifest().skills.any((k) => k.name == 'move')) {
      print('  no move skill: skipped');
      return;
    }
    await session.odometry.waitFresh();
    final a = session.odometry.pose!;
    backend.next = [const SkillCall('move', {'distance_m': 2.0})];
    final running = agent.handle('far');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await agent.handle('멈춰');
    final r = await running;
    await Future<void>.delayed(const Duration(seconds: 1));
    final b = session.odometry.pose!;
    final c = session.odometry.pose!;
    final d = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
    print('  stopped after ${d.toStringAsFixed(2)} m of 2.0 (${r.error ?? r.results.lastOrNull})');
    expect(d, lessThan(1.5));
    await Future<void>.delayed(const Duration(seconds: 1));
    final still = session.odometry.pose!;
    expect(math.sqrt(math.pow(still.x - c.x, 2) + math.pow(still.y - c.y, 2)), lessThan(0.03), reason: 'at rest');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
