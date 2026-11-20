import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

/// A fake proxy: answers each request with the next canned response and records what it was sent.
class FakeProxy {
  FakeProxy(this.responses);
  final List<(int, Map<String, Object?>)> responses;
  final requests = <Map<String, dynamic>>[];
  final headers = <Map<String, String>>[];

  late final client = MockClient((request) async {
    requests.add(jsonDecode(request.body) as Map<String, dynamic>);
    headers.add(request.headers);
    final (status, body) = responses.removeAt(0);
    return http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json; charset=utf-8'});
  });
}

Map<String, Object?> toolUse(String id, String name, Map<String, Object?> input) =>
    {'type': 'tool_use', 'id': id, 'name': name, 'input': input};

void main() {
  late FakeConnection robot;
  late DriveController drive;
  late NavigationController nav;

  setUp(() {
    robot = FakeConnection();
    final ros = RosClient(robot);
    drive = DriveController(ros, period: const Duration(milliseconds: 10))
      ..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    nav = NavigationController(ros);
  });
  tearDown(() {
    drive.dispose();
    nav.dispose();
  });

  RobotAgent agentWith(FakeProxy proxy) => RobotAgent(drive: drive, nav: nav, backend: CloudBackend(
      endpoint: Uri.parse('http://pc:8787/v1/plan'), token: 'secret', client: proxy.client));

  test('runs the tool calls, reports results with their ids, and ends on the text reply', () async {
    const thinking = {'type': 'thinking', 'thinking': '', 'signature': 'sig-1'};
    final proxy = FakeProxy([
      (200, {'stop_reason': 'tool_use', 'content': [
        thinking,
        {'type': 'text', 'text': '조금 앞으로 갈게요.'},
        toolUse('call_1', 'move', {'distance_m': 0.03}),
      ]}),
      (200, {'stop_reason': 'end_turn', 'content': [
        {'type': 'text', 'text': '앞으로 3센티 이동했어요.'},
      ]}),
    ]);
    final run = await agentWith(proxy).handle('앞으로 3센티');

    expect(run.ok, isTrue, reason: '${run.error} ${run.results}');
    expect(run.replies, ['조금 앞으로 갈게요.', '앞으로 3센티 이동했어요.']);
    expect(run.results.single.message, contains('Moved about 0.03 m forward'));

    final first = proxy.requests[0];
    expect(proxy.headers[0]['x-proxy-token'], 'secret');
    expect(first['system'], contains('differential-drive base'));
    expect((first['tools'] as List).map((t) => t['name']), containsAll(['stop', 'move', 'rotate']));
    final firstUser = (first['messages'] as List).single as Map;
    expect(firstUser['content'], allOf(contains('Robot status: '), endsWith('앞으로 3센티')));

    final second = proxy.requests[1]['messages'] as List;
    expect(second, hasLength(3));
    expect(second[1]['role'], 'assistant');
    expect(second[1]['content'][0], thinking, reason: 'thinking blocks go back unchanged');
    final result = (second[2]['content'] as List).single as Map;
    expect(result['type'], 'tool_result');
    expect(result['tool_use_id'], 'call_1');
    expect(result.containsKey('is_error'), isFalse);
    expect(jsonDecode(result['content'] as String)['ok'], isTrue);
    expect(second.first, firstUser, reason: 'the system prompt and first turn stay byte-identical (cache)');
  });

  test('a call the validator refuses ends the instruction without asking the model again', () async {
    final proxy = FakeProxy([
      (200, {'stop_reason': 'tool_use', 'content': [toolUse('c1', 'strafe', {'distance_m': 1})]}),
    ]);
    final run = await agentWith(proxy).handle('옆으로 1미터');
    expect(run.ok, isFalse);
    expect(run.results.single.message, contains('not available'));
    expect(proxy.requests, hasLength(1));
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel'), isEmpty);
  });

  test('a text-only answer runs nothing', () async {
    final proxy = FakeProxy([
      (200, {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': '그건 할 수 없어요.'}]}),
    ]);
    final run = await agentWith(proxy).handle('날아가');
    expect(run.ok, isTrue);
    expect(run.replies, ['그건 할 수 없어요.']);
    expect(run.results, isEmpty);
  });

  test('proxy errors, refusals and cut-off tool calls are reported, nothing moves', () async {
    var run = await agentWith(FakeProxy([(502, {'error': 'the proxy could not reach the Claude API'})])).handle('가');
    expect(run.error, contains('could not reach the Claude API'));

    run = await agentWith(FakeProxy([(200, {'stop_reason': 'refusal', 'content': []})])).handle('가');
    expect(run.replies, ['The model declined this request.']);
    expect(run.results, isEmpty);

    run = await agentWith(FakeProxy([
      (200, {'stop_reason': 'max_tokens', 'content': [toolUse('c', 'move', {'distance_m': 1})]}),
    ])).handle('가');
    expect(run.error, contains('cut off'));
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel'), isEmpty);
  });

  test('a step a person interrupts ends the instruction; the model is not asked to continue', () async {
    final proxy = FakeProxy([
      (200, {'stop_reason': 'tool_use', 'content': [toolUse('c1', 'move', {'distance_m': 1.0})]}),
    ]);
    final agent = agentWith(proxy);
    final running = agent.handle('앞으로 1미터');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    drive.manualInput = () => const DriveCommand(linearX: -0.1); // a person takes the sticks
    drive.tick();
    final run = await running;
    expect(run.ok, isFalse);
    expect(proxy.requests, hasLength(1));
  });

  test('the system prompt does not change with the robot state (so it stays cached)', () async {
    final proxy = FakeProxy([
      (200, {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': 'a'}]}),
      (200, {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': 'b'}]}),
    ]);
    final agent = agentWith(proxy);
    await agent.handle('상태');
    drive.manualInput = () => const DriveCommand(linearX: 0.1);
    drive.tick();
    await agent.handle('상태');
    expect(proxy.requests[0]['system'], proxy.requests[1]['system']);
    expect(proxy.requests[0]['tools'], proxy.requests[1]['tools']);
  });
}
