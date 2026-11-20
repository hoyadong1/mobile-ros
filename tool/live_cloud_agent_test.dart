// Live end-to-end check of the AI assistant with a real model: natural-language instructions go
// through tool/agent_proxy.py (Claude or Gemini) and move a running rosbridge robot (a simulation).
// Not part of `flutter test`; start the simulation and the proxy, then:
//   flutter test tool/live_cloud_agent_test.dart --dart-define=PROXY=http://127.0.0.1:8787/v1/plan \
//       --dart-define=PROXY_TOKEN=<token> [--dart-define=ROBOT_HOST=127.0.0.1 --dart-define=ROBOT_PORT=9090]
// The model is not deterministic: these checks are about what the robot ends up doing, not wording.
// ignore_for_file: avoid_print -- progress output is the point of this manual check
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');
/// With `--dart-define=LOCAL=<model.gguf>`: the app's real setup, the on-device model routed with the cloud.
const localModel = String.fromEnvironment('LOCAL');

void main() {
  late RosConnection connection;
  late RobotSession session;
  late RobotAgent agent;
  RouterBackend? router;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    final cloud = CloudBackend(endpoint: Uri.parse(proxy), token: token);
    if (localModel.isNotEmpty) {
      router = RouterBackend(local: LocalBackend(NativeLlm(localModel)), cloud: cloud);
    }
    agent = RobotAgent.forSession(session, router ?? cloud);
  });

  tearDownAll(() {
    session.dispose();
    connection.close();
  });

  Future<AgentRun> say(String instruction) async {
    final watch = Stopwatch()..start();
    final run = await agent.handle(instruction);
    print('\n> $instruction  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s${router == null ? '' : ', ${router!.lastRoute.name}'})');
    for (final e in agent.log.entries.skipWhile((e) => e.text != instruction).skip(1)) {
      print('  ${e.kind.name}${e.ok == null ? '' : e.ok! ? ' ok' : ' FAILED'}: ${e.text}');
    }
    if (run.error != null) print('  error: ${run.error}');
    return run;
  }

  test('a two-step instruction moves and turns the robot', () async {
    await session.prepare();
    expect(await session.odometry.waitFresh(timeout: const Duration(seconds: 5)), isTrue, reason: 'odometry');
    final before = session.odometry.pose!;
    final run = await say('앞으로 30센티 가고 왼쪽으로 90도 돌아');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = session.odometry.pose!;
    final moved = math.sqrt(math.pow(after.x - before.x, 2) + math.pow(after.y - before.y, 2));
    final turned = math.atan2(math.sin(after.yaw - before.yaw), math.cos(after.yaw - before.yaw)) * 180 / math.pi;
    print('  odometry: moved ${moved.toStringAsFixed(3)} m, turned ${turned.toStringAsFixed(1)}°');
    expect(run.ok, isTrue);
    expect(run.results, hasLength(2));
    expect(moved, closeTo(0.3, 0.05));
    expect(turned, closeTo(90, 5));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a status question uses no motion', () async {
    final run = await say('지금 상태 알려줘');
    expect(run.ok, isTrue);
    expect(run.replies, isNotEmpty);
    expect(agent.log.entries.where((e) => e.text.startsWith('move') || e.text.startsWith('rotate')), hasLength(2),
        reason: 'only the two calls from the first test');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('an impossible request is explained, not attempted', () async {
    final calls = agent.log.entries.where((e) => e.kind.name == 'call').length;
    final run = await say('하늘로 날아올라');
    expect(run.replies, isNotEmpty);
    expect(agent.log.entries.where((e) => e.kind.name == 'call').length, calls, reason: 'nothing ran');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('the model looks through the camera and describes what it sees', () async {
    final run = await say('카메라로 지금 뭐가 보이는지 알려줘');
    final looked = agent.log.entries.where((e) => e.kind.name == 'result' && e.image != null).toList();
    print('  camera topic: ${session.drive.profile?.cameraTopic}, picture ${looked.lastOrNull?.image?.length} bytes');
    expect(run.ok, isTrue);
    expect(looked, isNotEmpty, reason: 'it used look');
    expect(run.replies.join(), isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('what was just done is saved as a routine and run again by its name', () async {
    final first = await say('앞으로 20센티 가고 오른쪽으로 45도 돌아');
    expect(first.ok, isTrue);
    final saved = await say('방금 한 동작을 짧은순찰이라는 루틴으로 저장해');
    expect(saved.ok, isTrue);
    final routine = session.routines.find('짧은순찰');
    expect(routine, isNotNull, reason: 'saved under the name the person gave');
    print('  saved: ${routine!.steps.map((s) => s.call).join(', ')}');
    expect(routine.steps.map((s) => s.call!.name), ['move', 'rotate']);
    final start = session.odometry.pose!;
    final again = await say('짧은순찰 실행해');
    expect(again.ok, isTrue);
    final end = session.odometry.pose!;
    final distance = math.sqrt(math.pow(end.x - start.x, 2) + math.pow(end.y - start.y, 2));
    print('  routine run: moved ${distance.toStringAsFixed(3)} m');
    expect(distance, closeTo(0.2, 0.05));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a saved place is reached by its name', () async {
    await session.prepare();
    await session.places.save(const Place('충전기', -1.5, -0.5));
    final run = await say('충전기로 가줘');
    expect(run.ok, isTrue);
    expect(run.results.last.message, 'Arrived at 충전기.');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a map position is reached through Nav2', () async {
    final run = await say('지도에서 (-0.5, -0.5) 위치로 이동해');
    expect(run.ok, isTrue);
    expect(run.results.last.message, startsWith('Arrived'));
  }, timeout: const Timeout(Duration(minutes: 3)));
}
