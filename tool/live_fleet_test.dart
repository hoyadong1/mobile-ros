// ignore_for_file: avoid_print
// A fleet of TurtleBot3s on one connection (scripts/ros2_jazzy_multi_sim.sh, robot1..robotN): each robot's
// own routines, the fleet assistant driving and navigating several robots at once, and Stop all.
//   FLUTTER=<flutter> DISTRO=jazzy MULTI=1 ROBOTS=3 bash scripts/dev-env/sim_live_test.sh tool/live_fleet_test.dart
//   --dart-define=ROBOTS=3        how many robots the simulation has (default 2)
//   --dart-define=VIA=zenoh       the fleet on Zenoh (RMW=rmw_zenoh_cpp), no rosbridge
//   --dart-define=BACKEND=cloud   also give the fleet assistant sentences (proxy on PROXY with PROXY_TOKEN);
//   --dart-define=BACKEND=local --dart-define=LOCAL=<model.gguf>   the same with the on-device model only
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/fleet_agent.dart';
import 'package:ros_tester/agent/local/fleet_local_backend.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/routines.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';
import 'dds_test_support.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const robotCount = int.fromEnvironment('ROBOTS', defaultValue: 2);
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');
const backendName = String.fromEnvironment('BACKEND', defaultValue: 'scripted');
const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');
const localModel = String.fromEnvironment('LOCAL');

class Scripted extends AgentBackend {
  final plans = <List<SkillCall>>[];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: plans.removeAt(0));
}

double dist(Pose2D a, Pose2D b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
double turned(Pose2D a, Pose2D b) => math.atan2(math.sin(b.yaw - a.yaw), math.cos(b.yaw - a.yaw)) * 180 / math.pi;

void main() {
  ZenohRosSession? zenoh;
  late RosConnection connection;
  late List<RobotSession> robots;
  final scripted = Scripted();
  late FleetAgent fleet;

  Map<String, Pose2D> poses() => {for (final s in robots) s.name: s.odometry.pose!};
  /// Waits until no robot has moved for half a second (Nav2 may still be settling after "arrived").
  Future<void> settle() async {
    final end = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(end)) {
      final a = poses();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final still = robots.every((s) => dist(a[s.name]!, s.odometry.pose!) < 0.002 &&
          turned(a[s.name]!, s.odometry.pose!).abs() < 0.5);
      if (still) return;
    }
  }
  String moves(Map<String, Pose2D> from) =>
      robots.map((s) => '${s.name} ${dist(from[s.name]!, s.odometry.pose!).toStringAsFixed(3)} m').join(', ');

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    if (via == 'zenoh') {
      zenoh = await ZenohRosSession.open(router: host, interfaces: bundledInterfaces());
      connection = zenoh!.connect();
    } else {
      connection = RosConnection(host, port);
      await connection.ready;
    }
    var names = <String>[];
    // On Zenoh the graph fills in over a few seconds.
    for (var i = 0; i < 30 && names.length < robotCount; i++) {
      names = (await RobotCapabilities.discover(connection)).robotNamespaces();
      if (names.length < robotCount) await Future<void>.delayed(const Duration(seconds: 1));
    }
    print('  connection: $via; robots: $names');
    expect(names, [for (var i = 1; i <= robotCount; i++) '/robot$i']);
    robots = [for (final ns in names) RobotSession(connection: connection, ip: host, port: port, namespace: ns)];
    for (final s in robots) {
      await s.prepare();
      await s.odometry.waitFresh();
    }
    fleet = FleetAgent(robots, scripted);
  });

  tearDownAll(() async {
    fleet.dispose();
    for (final s in robots) { s.dispose(); }
    connection.close();
    zenoh?.close();
  });

  test('every robot gets its own routine book, and routines on two robots run at once', () async {
    final one = robots[0], two = robots[1];
    await one.routines.load();
    await two.routines.load();
    await one.routines.save(Routine(id: 'a', name: 'patrol', steps: const [
      RoutineStep.call(SkillCall('move', {'distance_m': 0.25})),
      RoutineStep.call(SkillCall('rotate', {'angle_deg': 90})),
      RoutineStep.call(SkillCall('rotate', {'angle_deg': -90})),
      RoutineStep.call(SkillCall('move', {'distance_m': -0.25})),
    ]));
    await two.routines.save(Routine(id: 'b', name: 'spin', steps: const [
      RoutineStep.call(SkillCall('rotate', {'angle_deg': -90})),
      RoutineStep.call(SkillCall('rotate', {'angle_deg': 90})),
    ]));
    // A fresh load from storage, as after an app restart: each robot sees only its own routine.
    await one.routines.load();
    await two.routines.load();
    print('  ${one.name} routines: ${one.routines.routines.map((r) => r.name)}; '
        '${two.name}: ${two.routines.routines.map((r) => r.name)}');
    expect(one.routines.find('patrol'), isNotNull);
    expect(one.routines.find('spin'), isNull);
    expect(two.routines.find('spin'), isNotNull);
    expect(two.routines.find('patrol'), isNull);

    final a1 = RobotAgent.forSession(one, scripted), a2 = RobotAgent.forSession(two, scripted);
    final start = poses();
    final watch = Stopwatch()..start();
    // Watch the middle of both routines: robot1 out 25 cm and turned left, robot2 turned right, at once.
    var farthest1 = 0.0, minTurn2 = 0.0;
    final watcher = Timer.periodic(const Duration(milliseconds: 100), (_) {
      farthest1 = math.max(farthest1, dist(start[one.name]!, one.odometry.pose!));
      minTurn2 = math.min(minTurn2, turned(start[two.name]!, two.odometry.pose!));
    });
    final runs = await Future.wait([a1.runRoutine(one.routines.find('patrol')!), a2.runRoutine(two.routines.find('spin')!)]);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    watcher.cancel();
    final now = poses();
    print('  both routines in ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: ${one.name} out '
        '${farthest1.toStringAsFixed(3)} m, ${two.name} turned to ${minTurn2.toStringAsFixed(0)}°; back: ${moves(start)}, '
        '${one.name} ${turned(start[one.name]!, now[one.name]!).toStringAsFixed(0)}°, '
        '${two.name} ${turned(start[two.name]!, now[two.name]!).toStringAsFixed(0)}°');
    expect(runs.every((r) => r.ok), isTrue, reason: runs.map((r) => r.error).join(' / '));
    expect(farthest1, closeTo(0.25, 0.04));
    expect(minTurn2, closeTo(-90, 8));
    expect(dist(start[one.name]!, now[one.name]!), lessThan(0.06), reason: 'patrol comes back');
    expect(turned(start[one.name]!, now[one.name]!).abs(), lessThan(8));
    expect(dist(start[two.name]!, now[two.name]!), lessThan(0.05), reason: 'turns in place');
    expect(turned(start[two.name]!, now[two.name]!).abs(), lessThan(8));
    for (final s in robots.skip(2)) {
      expect(dist(start[s.name]!, now[s.name]!), lessThan(0.01), reason: '${s.name} was not asked to move');
    }
    a1.dispose();
    a2.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the fleet assistant drives every robot at the same time', () async {
    scripted.plans.add([for (final s in robots) SkillCall('move', {'robot': s.name, 'distance_m': 0.3})]);
    final start = poses();
    final watch = Stopwatch()..start();
    final run = await fleet.handle('all robots forward 30 cm');
    final took = watch.elapsedMilliseconds / 1000;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    print('  ${robots.length} robots in ${took.toStringAsFixed(1)} s: ${moves(start)}');
    expect(run.ok, isTrue, reason: '${run.error} ${run.results.map((r) => r.message)}');
    for (final s in robots) {
      expect(dist(start[s.name]!, s.odometry.pose!), closeTo(0.3, 0.04), reason: s.name);
    }
    scripted.plans.add([for (final s in robots) SkillCall('move', {'robot': s.name, 'distance_m': -0.3})]);
    expect((await fleet.handle('all robots back 30 cm')).ok, isTrue);
    // One 30 cm drive takes about 2 s; one after another would be robots × that.
    expect(took, lessThan(2.0 * robots.length - 0.5), reason: 'the robots moved together, not in turn');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the fleet assistant sends every robot to its own map goal, and they all arrive', () async {
    // 0.8 m further along +x (open floor from every start position; Nav2 stops within 0.25 m of a goal) from where each one is now (the map is AMCL's, so read the robot's map pose).
    final ros = RosClient(connection);
    final goals = <String, Pose2D>{};
    for (final s in robots) {
      final msg = await ros.subscribe('${s.namespace}/amcl_pose', type: 'geometry_msgs/msg/PoseWithCovarianceStamped')
          .first.timeout(const Duration(seconds: 20), onTimeout: () => throw StateError('no AMCL pose from ${s.name}'));
      final p = msg['pose']['pose']['position'];
      goals[s.name] = Pose2D((p['x'] as num) + 0.8, (p['y'] as num).toDouble(), 0);
    }
    print('  goals: ${goals.entries.map((e) => '${e.key} (${e.value.x.toStringAsFixed(2)}, ${e.value.y.toStringAsFixed(2)})').join(', ')}');
    scripted.plans.add([
      for (final s in robots)
        SkillCall('navigate_to', {'robot': s.name, 'x': goals[s.name]!.x, 'y': goals[s.name]!.y}),
    ]);
    final start = poses();
    final watch = Stopwatch()..start();
    final run = await fleet.handle('every robot 80 cm ahead on the map').timeout(const Duration(minutes: 3),
        onTimeout: () { fleet.stop(); return AgentRun(instruction: '', error: 'navigation timed out'); });
    print('  navigation in ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: ${moves(start)}; '
        '${run.results.map((r) => r.message).join(' | ')}');
    expect(run.ok, isTrue, reason: '${run.error}');
    for (final s in robots) {
      expect(dist(start[s.name]!, s.odometry.pose!), greaterThan(0.5), reason: s.name);
    }
    // And back to the start, so the next checks have open floor ahead.
    scripted.plans.add([
      for (final s in robots) SkillCall('navigate_to', {'robot': s.name, 'x': goals[s.name]!.x - 0.8, 'y': goals[s.name]!.y, 'yaw_deg': 0}),
    ]);
    final back = await fleet.handle('everyone back').timeout(const Duration(minutes: 3),
        onTimeout: () { fleet.stop(); return AgentRun(instruction: '', error: 'navigation timed out'); });
    print('  back: ${back.results.map((r) => r.message).join(' | ')}');
    expect(back.ok, isTrue, reason: '${back.error}');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('a wrong robot name is refused before anyone moves', () async {
    scripted.plans.add([
      SkillCall('move', {'robot': robots[0].name, 'distance_m': 0.2}),
      const SkillCall('move', {'robot': 'robot9', 'distance_m': 0.2}),
    ]);
    await settle();
    final start = poses();
    final run = await fleet.handle('robot1 and robot9 forward');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    print('  refused: ${run.results.map((r) => r.message).join(' | ')}; ${moves(start)}');
    expect(run.ok, isFalse);
    expect(run.results.single.message, contains('robot9'));
    for (final s in robots) {
      expect(dist(start[s.name]!, s.odometry.pose!), lessThan(0.01), reason: s.name);
    }
  });

  test('what the fleet just did is saved as a fleet routine and runs again the same way', () async {
    final book = FleetAgent.bookFor(robots.first);
    await book.load();
    final routineFleet = FleetAgent(robots, scripted, routines: book);
    addTearDown(routineFleet.dispose);
    final last = robots.last;
    scripted.plans.add([
      SkillCall('move', {'robot': robots.first.name, 'distance_m': 0.2}),
      SkillCall('rotate', {'robot': last.name, 'angle_deg': 45}),
    ]);
    await settle();
    expect((await routineFleet.handle('robot1 forward, last robot turn')).ok, isTrue);
    scripted.plans.add([const SkillCall('save_routine', {'name': 'close up'})]);
    final saved = await routineFleet.handle('save that as close up');
    print('  ${saved.results.map((r) => r.message).join(' | ')}');
    expect(saved.ok, isTrue);
    // Saved for this connection, as an app restart would read it back.
    final again = FleetAgent.bookFor(robots.first);
    await again.load();
    expect(again.find('close up')!.steps.map((s) => s.call!.args['robot']), [robots.first.name, last.name]);
    again.dispose();

    await settle();
    final start = poses();
    final run = await routineFleet.runRoutine(book.find('close up')!);
    await settle();
    print('  routine: ${run.results.map((r) => r.message).join(' | ')}; ${moves(start)}, '
        '${last.name} turned ${turned(start[last.name]!, last.odometry.pose!).toStringAsFixed(0)}°');
    expect(run.ok, isTrue, reason: '${run.error}');
    expect(dist(start[robots.first.name]!, robots.first.odometry.pose!), closeTo(0.2, 0.04));
    expect(turned(start[last.name]!, last.odometry.pose!), closeTo(45, 8));
    for (final s in robots.sublist(1, robots.length - 1)) {
      expect(dist(start[s.name]!, s.odometry.pose!), lessThan(0.01), reason: '${s.name} is not in the routine');
    }
    // Back where they were for the next checks.
    scripted.plans.add([
      SkillCall('move', {'robot': robots.first.name, 'distance_m': -0.4}),
      SkillCall('rotate', {'robot': last.name, 'angle_deg': -90}),
    ]);
    expect((await routineFleet.handle('back')).ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('Stop all halts every robot mid-drive', () async {
    scripted.plans.add([for (final s in robots) SkillCall('move', {'robot': s.name, 'distance_m': 1.5})]);
    final start = poses();
    final running = fleet.handle('all robots forward 1.5 m');
    // Stop once every robot is under way (with several robots the simulation runs slower than real time).
    final end = DateTime.now().add(const Duration(seconds: 8));
    while (robots.any((s) => dist(start[s.name]!, s.odometry.pose!) < 0.1) && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final watch = Stopwatch()..start();
    final stopped = await fleet.handle('stop');
    final run = await running.timeout(const Duration(seconds: 10));
    print('  headings at start ${robots.map((s) => '${s.name} ${(start[s.name]!.yaw * 180 / math.pi).toStringAsFixed(0)}°').join(', ')}; '
        '${run.results.map((r) => r.message).join(' | ')}');
    final stopMs = watch.elapsedMilliseconds;
    final atStop = poses();
    await Future<void>.delayed(const Duration(seconds: 2));
    print('  stopped (drive ended) in $stopMs ms after ${moves(start)}; '
        'drift afterwards ${robots.map((s) => dist(atStop[s.name]!, s.odometry.pose!).toStringAsFixed(3)).join(', ')} m');
    expect(stopped.ok, isTrue);
    expect(run.ok, isFalse, reason: 'the drive was interrupted');
    for (final s in robots) {
      final moved = dist(start[s.name]!, s.odometry.pose!);
      expect(moved, inInclusiveRange(0.1, 1.0), reason: '${s.name} started and was stopped well short of 1.5 m');
      expect(dist(atStop[s.name]!, s.odometry.pose!), lessThan(0.03), reason: '${s.name} stays stopped');
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the fleet assistant understands sentences ($backendName)', () async {
    if (backendName == 'scripted') {
      print('  skipped: pass --dart-define=BACKEND=cloud or local');
      return;
    }
    final AgentBackend backend = backendName == 'local'
        ? RouterBackend(local: FleetLocalBackend(LocalBackend(NativeLlm(localModel))))
        : CloudBackend(endpoint: Uri.parse(proxy), token: token);
    final words = FleetAgent(robots, backend);
    addTearDown(words.dispose);
    final last = robots.last;
    Future<(AgentRun, Map<String, Pose2D>)> say(String text) async {
      await settle();
      final start = poses();
      final watch = Stopwatch()..start();
      final run = await words.handle(text);
      await Future<void>.delayed(const Duration(milliseconds: 800));
      print('> $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)\n'
          '  ${run.results.map((r) => r.message).join(' | ')}${run.error == null ? '' : '  ERROR: ${run.error}'}\n'
          '  reply: ${run.replies.join(' / ')}\n  ${moves(start)}');
      return (run, start);
    }

    final (go, s1) = await say('robot1은 앞으로 20센티 가고, ${last.name}는 왼쪽으로 90도 돌아');
    expect(go.ok, isTrue);
    expect(dist(s1['robot1']!, robots[0].odometry.pose!), closeTo(0.2, 0.05));
    expect(turned(s1[last.name]!, last.odometry.pose!), closeTo(90, 10));
    for (final s in robots.sublist(1, robots.length - 1)) {
      expect(dist(s1[s.name]!, s.odometry.pose!), lessThan(0.01), reason: '${s.name} was not named');
    }

    final (all, s2) = await say('all robots: go back 15 cm');
    expect(all.ok, isTrue);
    for (final s in robots) {
      expect(dist(s2[s.name]!, s.odometry.pose!), closeTo(0.15, 0.05), reason: s.name);
    }

    final (unknown, s3) = await say('robot9 앞으로 가');
    expect(unknown.results.where((r) => r.ok), isEmpty, reason: 'no robot9 in this fleet');
    for (final s in robots) {
      expect(dist(s3[s.name]!, s.odometry.pose!), lessThan(0.01), reason: s.name);
    }

    // The names people gave the robots work as their names.
    await robots.first.memory.setProfile(RobotPersona.nameKey, '순돌이');
    await last.memory.setProfile(RobotPersona.nameKey, '배달이');
    final (byName, s4) = await say('순돌이는 앞으로 20센티 가고, 배달이는 왼쪽으로 90도 돌아');
    expect(byName.ok, isTrue);
    expect(dist(s4[robots.first.name]!, robots.first.odometry.pose!), closeTo(0.2, 0.05));
    expect(turned(s4[last.name]!, last.odometry.pose!), closeTo(90, 10));
    for (final s in robots.sublist(1, robots.length - 1)) {
      expect(dist(s4[s.name]!, s.odometry.pose!), lessThan(0.01), reason: '${s.name} was not named');
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
