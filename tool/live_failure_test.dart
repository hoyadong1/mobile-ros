// ignore_for_file: avoid_print
// What happens when things go wrong, on the TurtleBot3 + Nav2 simulation:
// a goal that cannot be reached, a person taking the sticks mid-move, a dead camera topic, a question
// nobody answers, and the app's connection dropping while the robot is moving.
//   FLUTTER=<flutter> DISTRO=jazzy bash scripts/dev-env/sim_live_test.sh tool/live_failure_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const distro = String.fromEnvironment('ROS_DISTRO', defaultValue: String.fromEnvironment('DISTRO', defaultValue: 'jazzy'));
/// The WSL distro the robot runs in (sim_live_test.sh passes the one it started).
const wslDistro = String.fromEnvironment('WSL_DISTRO', defaultValue: 'ros-$distro');

class Scripted extends AgentBackend {
  List<SkillCall> next = const [];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: next);
}

double dist(Pose2D a, Pose2D b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

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
    await session.odometry.waitFresh();
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

  test('a goal outside the map fails with a reason, and the robot still obeys afterwards', () async {
    final a = session.odometry.pose!;
    final watch = Stopwatch()..start();
    final r = await run(const SkillCall('navigate_to', {'x': 40.0, 'y': 40.0})).timeout(const Duration(minutes: 2));
    print('  navigate_to (40, 40): ${r.results.lastOrNull} after ${watch.elapsed.inSeconds} s; '
        'robot moved ${dist(a, session.odometry.pose!).toStringAsFixed(2)} m');
    expect(r.ok, isFalse);
    expect(session.nav.isActive, isFalse, reason: 'no goal left running');
    final again = await run(const SkillCall('move', {'distance_m': 0.2}));
    print('  then move 0.2: ${again.results.lastOrNull}');
    expect(again.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a person on the sticks takes over from the assistant at once', () async {
    final a = session.odometry.pose!;
    backend.next = [const SkillCall('move', {'distance_m': 2.0})];
    final running = agent.handle('far');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    session.drive.manualInput = () => const DriveCommand(angularZ: 0.4); // the person turns the robot
    final r = await running.timeout(const Duration(seconds: 5));
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final b = session.odometry.pose!;
    session.drive.manualInput = () => DriveCommand.stop;
    final turned = (b.yaw - a.yaw).abs() * 180 / math.pi;
    print('  assistant: ${r.results.lastOrNull ?? r.error}; moved ${dist(a, b).toStringAsFixed(2)} m of 2.0, '
        'then turned ${turned.toStringAsFixed(0)}° by hand');
    expect(r.ok, isFalse);
    expect(dist(a, b), lessThan(1.0));
    expect(turned, greaterThan(10), reason: 'the stick command got through');
    await Future<void>.delayed(const Duration(seconds: 1));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a camera that sends nothing: look fails in a few seconds instead of hanging', () async {
    final watch = Stopwatch()..start();
    final profile = session.drive.profile!;
    session.drive.configure(profile.copyWith(cameraTopic: '/no_such_camera/image_raw/compressed'),
        (await session.capabilities()).rosVersion);
    final r = await run(const SkillCall('look'));
    session.drive.configure(profile, (await session.capabilities()).rosVersion);
    print('  look: ${r.results.lastOrNull} after ${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
    expect(r.ok, isFalse);
    expect(watch.elapsed.inSeconds, lessThan(9));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('a question nobody answers is withdrawn by the robot and disappears', () async {
    session.requests.start();
    final repo = Directory.current.path.replaceAll(r'\', '/');
    final wslRepo = '/mnt/${repo[0].toLowerCase()}${repo.substring(2)}';
    final helper = await Process.start('wsl.exe', ['-d', wslDistro, '--', 'bash', '-lc',
      'source /opt/ros/$distro/setup.bash && python3 $wslRepo/robot_side/mobile_ros_phone.py ask Help Blocked Wait Reroute --timeout 6']);
    final out = helper.stdout.transform(utf8.decoder).join();
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (session.requests.pending.isEmpty && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(session.requests.pending, hasLength(1), reason: 'the question arrived');
    final code = await helper.exitCode.timeout(const Duration(seconds: 30));
    await Future<void>.delayed(const Duration(seconds: 1));
    print('  robot gave up: "${(await out).trim()}" (exit $code); still shown in the app: ${session.requests.pending.length}');
    expect(code, 1);
    expect(session.requests.pending, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  /// Drives on a second connection, cuts it without a stop command, and returns the metres the robot
  /// went on in the next 3 s and in the second after that.
  Future<(double, double)> dropWhileDriving() async {
    final driver = RosConnection(host, port);
    await driver.ready;
    final ros = RosClient(driver);
    final topic = session.drive.profile!.commandTopic;
    final type = session.drive.profile!.commandType;
    final pub = ros.advertise(topic, type);
    final twist = {'linear': {'x': 0.15, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}};
    final stamped = type.contains('Stamped');
    for (var i = 0; i < 15; i++) {
      pub.publish(stamped ? {'header': {'frame_id': 'base_link'}, 'twist': twist} : twist);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final a = session.odometry.pose!;
    driver.close(); // the link is gone: no stop command can be sent
    await Future<void>.delayed(const Duration(seconds: 3));
    final b = session.odometry.pose!;
    await Future<void>.delayed(const Duration(seconds: 1));
    final c = session.odometry.pose!;
    return (dist(a, b), dist(b, c));
  }

  test('the connection drops while driving: the robot runs on; with the watchdog it stops', () async {
    final (after, still) = await dropWhileDriving();
    print('  no watchdog: after the link dropped the robot went on ${after.toStringAsFixed(2)} m in 3 s, '
        '${still.toStringAsFixed(3)} m in the next second (${still < 0.01 ? 'stopped' : 'STILL MOVING'})');
    agent.stop(); // stop it by hand
    await Future<void>.delayed(const Duration(seconds: 1));

    // The same with robot_side/cmd_vel_watchdog.py running on the robot.
    final repo = Directory.current.path.replaceAll(r'\', '/');
    final wslRepo = '/mnt/${repo[0].toLowerCase()}${repo.substring(2)}';
    final watchdog = await Process.start('wsl.exe', ['-d', wslDistro, '--', 'bash', '-lc',
      'source /opt/ros/$distro/setup.bash && exec python3 $wslRepo/robot_side/cmd_vel_watchdog.py '
          '--topic ${session.drive.profile!.commandTopic} --timeout 0.5']);
    addTearDown(watchdog.kill);
    await Future<void>.delayed(const Duration(seconds: 6)); // discovery
    final (guarded, rest) = await dropWhileDriving();
    print('  watchdog: went on ${guarded.toStringAsFixed(2)} m, then ${rest.toStringAsFixed(3)} m '
        '(${rest < 0.01 ? 'stopped' : 'STILL MOVING'})');
    agent.stop();
    expect(rest, lessThan(0.01), reason: 'the watchdog stops a robot whose driver vanished');
    expect(guarded, lessThan(0.2), reason: 'within about a second at 0.15 m/s');

    // And it must not get in the way of normal driving. Backward: the drives above leave the robot
    // facing the wall (seen: an obstacle 0.14 m ahead), which would fail a forward move by itself.
    final ok = await run(const SkillCall('move', {'distance_m': -0.3}));
    print('  with the watchdog running, move -0.3: ${ok.results.lastOrNull}');
    expect(ok.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
