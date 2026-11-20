import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/robot_requests.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/widgets/help_request_dialog.dart';
import 'support/fake_ros_connection.dart';

class RecordingNotifier implements RobotNotifier {
  final shown = <String>[];
  final cleared = <String>[];
  @override
  Future<void> request(HelpRequest request) async => shown.add('ask:${request.id}');
  @override
  Future<void> notice(RobotNotice notice) async => shown.add('notice:${notice.title}');
  @override
  Future<void> clear(String requestId) async => cleared.add(requestId);
}

void main() {
  late FakeConnection robot;
  late RobotRequests requests;
  late RecordingNotifier notifier;
  var now = DateTime(2026, 11, 13, 10);

  void robotSays(String topic, Map<String, Object?> payload) => robot.events.add(
      {'op': 'publish', 'topic': topic, 'msg': {'data': jsonEncode(payload)}});
  List<Map> answers() => [
    for (final m in robot.sent)
      if (m['op'] == 'publish' && m['topic'] == RobotProtocol.answer) jsonDecode(m['msg']['data'] as String) as Map,
  ];
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() {
    robot = FakeConnection();
    notifier = RecordingNotifier();
    now = DateTime(2026, 11, 13, 10);
    requests = RobotRequests(RosClient(robot), notifier: notifier, clock: () => now)..start();
  });
  tearDown(() => requests.dispose());

  test('the app own notices (low battery, link lost, a failed schedule) are kept and shown outside the app', () {
    requests.add(RobotNotice('robot1', 'Battery low: 18 %.', NoticeLevel.warning));
    expect(requests.notices.single.message, 'Battery low: 18 %.');
    expect(notifier.shown, ['notice:robot1']);
  });

  test('listens on the ask and notify topics and advertises answers, all std_msgs/String', () {
    final subs = {for (final m in robot.sent) if (m['op'] == 'subscribe') m['topic']: m['type']};
    expect(subs, {RobotProtocol.ask: 'std_msgs/String', RobotProtocol.notify: 'std_msgs/String'});
    expect(robot.sent.where((m) => m['op'] == 'advertise').single['topic'], RobotProtocol.answer);
  });

  test('a question waits once (repeats ignored) and its answer goes back with the choice', () async {
    final q = {'id': 'q1', 'title': '문', 'message': '문 열어도 돼요?', 'options': ['열기', '기다리기'], 'urgent': true};
    robotSays(RobotProtocol.ask, q);
    robotSays(RobotProtocol.ask, q);
    await settle();
    expect(requests.pending.single.options, ['열기', '기다리기']);
    expect(requests.pending.single.urgent, isTrue);
    expect(notifier.shown, ['ask:q1']);

    expect(requests.answer('q1', 1), isTrue);
    expect(answers().single, {'id': 'q1', 'choice': '기다리기', 'index': 1});
    expect(requests.pending, isEmpty);
    expect(notifier.cleared, ['q1']);

    // The robot missed the answer and asks again: the same answer is sent, nothing new pops up.
    robotSays(RobotProtocol.ask, q);
    await settle();
    expect(answers(), hasLength(2));
    expect(requests.pending, isEmpty);
    expect(requests.answer('q1', 0), isFalse, reason: 'already answered');
  });

  test('the robot can withdraw a question; unanswered ones expire; dismiss tells the robot', () async {
    robotSays(RobotProtocol.ask, {'id': 'a', 'title': 'A', 'timeout_s': 30});
    robotSays(RobotProtocol.ask, {'id': 'b', 'title': 'B', 'timeout_s': 1});
    robotSays(RobotProtocol.ask, {'id': 'c', 'title': 'C'});
    await settle();
    expect(requests.pending.map((r) => r.id), ['a', 'b', 'c']);
    expect(requests.pending.first.options, ['OK'], reason: 'a question without options gets OK');

    robotSays(RobotProtocol.ask, {'id': 'a', 'cancel': true});
    await settle();
    expect(requests.pending.map((r) => r.id), ['b', 'c']);

    now = now.add(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // the expiry check runs every second
    expect(requests.pending.map((r) => r.id), ['c']);

    expect(requests.dismiss('c'), isTrue);
    expect(answers().single, {'id': 'c', 'dismissed': true});
  });

  test('notices are kept (bounded) and malformed messages are ignored', () async {
    robotSays(RobotProtocol.notify, {'title': '배터리', 'message': '20% 남았어요', 'level': 'warning'});
    robot.events.add({'op': 'publish', 'topic': RobotProtocol.notify, 'msg': {'data': 'not json'}});
    robot.events.add({'op': 'publish', 'topic': RobotProtocol.ask, 'msg': {'data': '{"title": "no id"}'}});
    await settle();
    expect(requests.notices.single.level, NoticeLevel.warning);
    expect(requests.pending, isEmpty);
    expect(notifier.shown, ['notice:배터리']);
  });

  testWidgets('the workspace shows the question on top and closes it when answered or withdrawn',
      (tester) async {
    // Made inside the test, so its streams run on the test's clock.
    requests.dispose();
    robot = FakeConnection();
    requests = RobotRequests(RosClient(robot));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RobotRequestsHost(
        requests: requests, robotName: 'robot:9090', child: const Text('workspace')))));
    robotSays(RobotProtocol.ask, {'id': 'd1', 'title': '도움 요청', 'message': '길이 막혔어요', 'options': ['돌아가', '기다려']});
    await tester.pump();
    await tester.pump();
    expect(find.text('길이 막혔어요'), findsOneWidget);
    expect(find.textContaining('robot:9090'), findsOneWidget);
    await tester.tap(find.byKey(const Key('robot-request-option-0')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-request')), findsNothing);
    expect(answers().single['choice'], '돌아가');

    robotSays(RobotProtocol.ask, {'id': 'd2', 'title': '두 번째'});
    await tester.pump();
    await tester.pump();
    expect(find.text('두 번째'), findsOneWidget);
    robotSays(RobotProtocol.ask, {'id': 'd2', 'cancel': true});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-request')), findsNothing);

    robotSays(RobotProtocol.notify, {'title': '도착', 'message': '충전기에 도착했어요'});
    await tester.pump();
    await tester.pump();
    expect(find.text('도착: 충전기에 도착했어요'), findsOneWidget);
    requests.dispose(); // stops its timer inside this test's clock
    requests = RobotRequests(RosClient(FakeConnection()));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
