// ignore_for_file: avoid_print
// The robot's memory with real models on the TurtleBot3 simulation: what it is told is remembered on the
// phone, it answers as the robot it was named, and each request goes to the model that should take it
// (lib/agent/route_policy.dart). Needs both models:
//   FLUTTER=<flutter> DISTRO=jazzy DEFINES="--dart-define=PROXY_TOKEN=t1 --dart-define=LOCAL=<model.gguf>" \
//     bash scripts/dev-env/sim_live_test.sh tool/live_persona_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');
const localModel = String.fromEnvironment('LOCAL');

void main() {
  late RosConnection connection;
  late RobotSession session;
  late RouterBackend router;
  late RobotAgent agent;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    await session.prepare();
    router = RouterBackend(local: LocalBackend(NativeLlm(localModel)),
        cloud: CloudBackend(endpoint: Uri.parse(proxy), token: token));
    agent = RobotAgent.forSession(session, router);
  });

  tearDownAll(() {
    agent.dispose();
    session.dispose();
    connection.close();
  });

  Future<AgentRun> say(String text) async {
    final watch = Stopwatch()..start();
    final run = await agent.handle(text);
    print('> $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, ${router.lastRoute.name}: ${router.lastDecision})');
    print('  ${[...run.replies, ...run.results.map((r) => r.message)].join(' | ')}${run.error == null ? '' : '  ERROR ${run.error}'}');
    return run;
  }

  test('told things are remembered, it answers as itself, and each request goes to the right model', () async {
    final named = await say('네 이름은 순돌이야');
    expect(router.lastRoute, Route.local, reason: 'remembering is the phone\'s job');
    expect(named.ok, isTrue);
    expect(session.memory.profile(RobotPersona.nameKey), '순돌이');
    await say('앞으로 나를 민수라고 불러');
    expect(Memory.user.profile(RobotPersona.callPersonKey), '민수');
    await say('2층 계단 근처는 가지 마, 기억해');
    expect(session.memory.ofKind('note').map((n) => n.text), contains('2층 계단 근처는 가지 마'));
    await say('너는 창고 야간 순찰 담당이야');
    expect(session.memory.profile(RobotPersona.roleKey), '창고 야간 순찰');

    final hello = await say('안녕! 너 이름이 뭐야?');
    expect(router.lastRoute, Route.cloud, reason: 'conversation goes online');
    expect(hello.replies.join(' '), contains('순돌'), reason: 'it answers as the robot it was named');

    final job = await say('너는 무슨 일을 해? 그리고 조심해야 할 곳 있어?');
    expect(router.lastRoute, Route.cloud);
    expect(job.replies.join(' '), anyOf(contains('순찰'), contains('patrol')));
    expect(job.replies.join(' '), contains('계단'));

    final move = await say('앞으로 20센티 가');
    expect(router.lastRoute, Route.local, reason: 'a direct command stays on the phone');
    expect(move.ok, isTrue);
    expect(session.memory.ofKind('episode').last.text, contains('앞으로 20센티 가'));

    final recall = await say('방금 뭐 했어?');
    expect(router.lastRoute, Route.cloud);
    print('  events: ${session.memory.ofKind('episode').map((e) => e.text).join(' / ')}');
    expect(recall.replies.join(' '), anyOf(contains('20'), contains('0.19'), contains('앞으로')),
        reason: 'it remembers what it just did');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
