// ignore_for_file: avoid_print
// Learning with real models on the TurtleBot3 simulation: the same request three times becomes a tool that
// "as usual" runs on the phone; the online model makes a tool when asked and uses it by name; the person's
// own word for something is learned and used. Needs both models:
//   FLUTTER=<flutter> DISTRO=jazzy DEFINES="--dart-define=PROXY_TOKEN=t1 --dart-define=LOCAL=<model.gguf>" \
//     bash scripts/dev-env/sim_live_test.sh tool/live_learning_test.dart
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/learned_tools.dart';
import 'package:ros_tester/agent/learning.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/memory.dart';
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

  Future<(AgentRun, double)> say(String text) async {
    await session.odometry.waitFresh();
    final a = session.odometry.pose!;
    var swept = 0.0, last = a.yaw;
    final sub = Stream.periodic(const Duration(milliseconds: 100)).listen((_) {
      final y = session.odometry.pose!.yaw;
      swept += math.atan2(math.sin(y - last), math.cos(y - last)).abs();
      last = y;
    });
    final watch = Stopwatch()..start();
    final run = await agent.handle(text);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await sub.cancel();
    final deg = swept * 180 / math.pi;
    print('> $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s, ${router.lastRoute.name}: ${router.lastDecision})');
    print('  ${[...run.replies, ...run.results.map((r) => r.message)].join(' | ')}${run.error == null ? '' : '  ERROR ${run.error}'}');
    print('  turned through ${deg.toStringAsFixed(0)}° in all');
    return (run, deg);
  }

  List<LearnedTool> tools() => [for (final i in session.memory.ofKind(LearnedTool.kind)) ?LearnedTool.fromJson(i.data)];

  test('a habit becomes a tool, the online model makes and uses one, and own words are learned', () async {
    for (var i = 0; i < 3; i++) {
      final (run, _) = await say('왼쪽으로 30도 돌고 오른쪽으로 30도 돌아');
      expect(run.ok, isTrue);
    }
    final habit = tools().where((t) => t.origin == 'habit').toList();
    print('  learned: ${habit.map((t) => '${t.name} ${t.phrases} ${t.steps}')}');
    expect(habit, hasLength(1), reason: 'three times is a habit');

    final (usual, swept) = await say('평소처럼 해');
    expect(router.lastRoute, Route.local);
    expect(usual.results.single.message, startsWith('Did my_usual_1'));
    expect(swept, greaterThan(45), reason: 'it turned left and back');

    final (made, _) = await say('앞으로 20센티 갔다가 뒤로 20센티 돌아오는 걸 shuttle이라는 도구로 만들어줘');
    print('  tools now: ${tools().map((t) => t.name)}');
    expect(tools().map((t) => t.name), contains('my_shuttle'), reason: '${made.error}');

    final (shuttle, _) = await say('shuttle 도구로 왕복해줘');
    expect(shuttle.results.map((r) => r.message).join(' '), contains('my_shuttle'));
    expect(shuttle.ok, isTrue);

    await say('거기라고 하면 왼쪽으로 45도라는 뜻이야');
    expect(Learning.aliases(Memory.user), {'거기': '왼쪽으로 45도'});
    final (there, deg) = await say('거기로 돌아');
    expect(there.ok, isTrue);
    expect(deg, closeTo(45, 12), reason: '"거기" was read as left 45 degrees');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
