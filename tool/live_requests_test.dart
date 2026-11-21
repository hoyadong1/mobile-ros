// ignore_for_file: avoid_print
// The robot asks the app something, for real: robot_side/mobile_ros_phone.py runs in the ROS WSL distro
// (as a robot program would) and the app's RobotRequests answers over rosbridge or Zenoh.
//   bash scripts/dev-env/sim_live_test.sh tool/live_requests_test.dart                    (DISTRO=jazzy)
//   RMW=rmw_zenoh_cpp DEFINES="--dart-define=VIA=zenoh --dart-define=RMW=rmw_zenoh_cpp" ...  (over Zenoh)
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'dds_test_support.dart';
import 'package:ros_tester/robot_requests.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');
const distro = String.fromEnvironment('ROS_DISTRO', defaultValue: String.fromEnvironment('DISTRO', defaultValue: 'jazzy'));
/// The WSL distro the robot runs in (sim_live_test.sh passes the one it started).
const wslDistro = String.fromEnvironment('WSL_DISTRO', defaultValue: 'ros-$distro');
const rmw = String.fromEnvironment('RMW');

/// Runs the robot-side helper in the ROS distro and returns its process.
Future<Process> robotHelper(List<String> args) {
  final repo = Directory.current.path.replaceAll(r'\', '/');
  final wslRepo = '/mnt/${repo[0].toLowerCase()}${repo.substring(2)}';
  final quoted = args.map((a) => "'${a.replaceAll("'", r"'\''")}'").join(' ');
  return Process.start('wsl.exe', ['-d', wslDistro, '--', 'bash', '-lc',
    'source /opt/ros/$distro/setup.bash && ${rmw.isEmpty ? '' : 'RMW_IMPLEMENTATION=$rmw '}'
        'python3 $wslRepo/robot_side/mobile_ros_phone.py $quoted']);
}

void main() {
  late RosConnection connection;
  late RobotRequests requests;
  ZenohRosSession? zenoh;

  setUpAll(() async {
    if (via == 'zenoh') {
      zenoh = await ZenohRosSession.open(router: host, interfaces: bundledInterfaces());
      connection = zenoh!.connect();
    } else {
      connection = RosConnection(host, port);
    }
    await connection.ready;
    requests = RobotRequests(RosClient(connection))..start();
  });

  tearDownAll(() {
    requests.dispose();
    connection.close();
    zenoh?.close();
  });

  Future<T> waitFor<T>(T? Function() check, String what, {Duration limit = const Duration(seconds: 30)}) async {
    final end = DateTime.now().add(limit);
    while (DateTime.now().isBefore(end)) {
      final v = check();
      if (v != null) return v;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('timed out waiting for $what');
  }

  test('the robot asks, the person answers, the robot gets the choice ($via)', () async {
    final watch = Stopwatch()..start();
    final robot = await robotHelper(['ask', '문 앞이에요', '문 열어도 될까요?', '열기', '기다리기', '--timeout', '40']);
    final out = robot.stdout.transform(utf8.decoder).join();
    final err = robot.stderr.transform(utf8.decoder).join();
    final question = await waitFor(() => requests.pending.firstOrNull, 'the question');
    print('  question after ${watch.elapsedMilliseconds} ms: ${question.title} / ${question.message} ${question.options}');
    expect(question.options, ['열기', '기다리기']);
    requests.answer(question.id, 0);
    final code = await robot.exitCode.timeout(const Duration(seconds: 20));
    final printed = (await out).trim();
    print('  robot got: "$printed" (exit $code) after ${watch.elapsedMilliseconds} ms');
    expect(printed, '열기', reason: await err);
    expect(code, 0);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the robot notifies ($via)', () async {
    final robot = await robotHelper(['notify', '배터리', '20% 남았어요', '--level', 'warning']);
    final notice = await waitFor(() => requests.notices.lastOrNull, 'the notice');
    print('  notice: ${notice.title}: ${notice.message} (${notice.level.name})');
    expect((notice.title, notice.message, notice.level), ('배터리', '20% 남았어요', NoticeLevel.warning));
    await robot.exitCode;
  }, timeout: const Timeout(Duration(minutes: 1)));
}
