import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  late FakeConnection connection;
  late RosClient client;
  setUp(() {
    connection = FakeConnection();
    client = RosClient(connection);
  });

  Map<String, dynamic> lastOp(String op) => connection.sent.lastWhere((m) => m['op'] == op);

  group('subscribe', () {
    test('subscribes on listen, delivers only its topic, unsubscribes with the same id on cancel', () async {
      final stream = client.subscribe('odom', type: 'nav_msgs/msg/Odometry', throttleRate: 200);
      expect(connection.sent, isEmpty, reason: 'nothing is sent before someone listens');

      final received = <Map<String, dynamic>>[];
      final sub = stream.listen(received.add);
      final subscribe = lastOp('subscribe');
      expect(subscribe['topic'], '/odom');
      expect(subscribe['type'], 'nav_msgs/msg/Odometry');
      expect(subscribe['throttle_rate'], 200);

      connection.events.add({'op': 'publish', 'topic': '/odom', 'msg': {'n': 1}});
      connection.events.add({'op': 'publish', 'topic': '/scan', 'msg': {'n': 2}});
      connection.events.add({'op': 'publish', 'topic': 'odom', 'msg': {'n': 3}}); // slash-less spelling
      connection.events.add({'op': 'action_feedback', 'topic': '/odom', 'values': {}});
      await pumpEventQueue();
      expect(received.map((m) => m['n']), [1, 3]);

      await sub.cancel();
      final unsubscribe = lastOp('unsubscribe');
      expect(unsubscribe['id'], subscribe['id']);
      expect(unsubscribe['topic'], '/odom');
    });

    test('two subscriptions to one topic have separate ids, so one cancel keeps the other alive', () async {
      final a = client.subscribe('/scan').listen((_) {});
      final b = client.subscribe('/scan').listen((_) {});
      final ids = connection.sent.where((m) => m['op'] == 'subscribe').map((m) => m['id']).toSet();
      expect(ids, hasLength(2));
      await a.cancel();
      expect(connection.sent.where((m) => m['op'] == 'unsubscribe'), hasLength(1));
      await b.cancel();
    });

    test('closes when the connection closes and does not send unsubscribe afterwards', () async {
      var done = false;
      client.subscribe('/odom').listen((_) {}, onDone: () => done = true);
      connection.close();
      await pumpEventQueue();
      expect(done, isTrue);
      expect(connection.sent.where((m) => m['op'] == 'unsubscribe'), isEmpty);
    });
  });

  group('advertise', () {
    test('shares one advertisement per topic and withdraws it with the last publisher', () {
      final a = client.advertise('/cmd_vel', 'geometry_msgs/msg/Twist');
      final b = client.advertise('cmd_vel', 'geometry_msgs/msg/Twist');
      expect(connection.sent.where((m) => m['op'] == 'advertise'), hasLength(1));

      a.publish({'linear': {'x': 0.1}});
      expect(lastOp('publish'), {'op': 'publish', 'topic': '/cmd_vel', 'msg': {'linear': {'x': 0.1}}});

      a.close();
      a.close(); // closing twice must not release twice
      expect(connection.sent.where((m) => m['op'] == 'unadvertise'), isEmpty);
      b.close();
      expect(lastOp('unadvertise')['topic'], '/cmd_vel');
      expect(() => a.publish({}), throwsStateError);
    });

    test('a new type replaces the advertisement; closing the old publisher does not withdraw the new one', () {
      final old = client.advertise('/cmd', 'geometry_msgs/msg/Twist');
      final current = client.advertise('/cmd', 'ackermann_msgs/msg/AckermannDriveStamped');
      expect(connection.sent.map((m) => m['op']), ['advertise', 'unadvertise', 'advertise']);
      old.close();
      expect(connection.sent.where((m) => m['op'] == 'unadvertise'), hasLength(1));
      current.close();
      expect(connection.sent.where((m) => m['op'] == 'unadvertise'), hasLength(2));
    });

    test('dispose withdraws every advertisement', () {
      client.advertise('/a', 'std_msgs/msg/String');
      client.advertise('/b', 'std_msgs/msg/String');
      client.dispose();
      expect(connection.sent.where((m) => m['op'] == 'unadvertise').map((m) => m['topic']), ['/a', '/b']);
      expect(() => client.advertise('/c', 'std_msgs/msg/String'), throwsStateError);
    });
  });

  test('callService passes through to the connection', () async {
    connection.serviceResponses['/rosapi/topics'] = {'topics': ['/odom']};
    expect(await client.callService('/rosapi/topics'), {'topics': ['/odom']});
    expect(connection.calls.single.$1, '/rosapi/topics');
  });

  group('sendActionGoal', () {
    const action = '/navigate_to_pose', type = 'nav2_msgs/action/NavigateToPose';

    test('sends the goal, streams its feedback and completes with the result', () async {
      final handle = client.sendActionGoal(action, type, {'pose': {}});
      final goal = lastOp('send_action_goal');
      expect(goal['id'], handle.id);
      expect(goal['action'], action);
      expect(goal['action_type'], type);
      expect(goal['feedback'], isTrue);

      final feedback = <Map<String, dynamic>>[];
      var feedbackClosed = false;
      handle.feedback.listen(feedback.add, onDone: () => feedbackClosed = true);
      connection.events.add({'op': 'action_feedback', 'id': handle.id, 'values': {'distance_remaining': 2.0}});
      connection.events.add({'op': 'action_feedback', 'id': 'someone_else', 'values': {'distance_remaining': 9.0}});
      connection.events.add({'op': 'action_result', 'id': handle.id, 'status': 4, 'result': true, 'values': {}});

      final result = await handle.result;
      expect(result.status, ActionStatus.succeeded);
      expect(result.code, 4);
      expect(feedback.single['distance_remaining'], 2.0);
      await pumpEventQueue();
      expect(feedbackClosed, isTrue);
      expect(handle.isDone, isTrue);
    });

    test('maps canceled and aborted codes, and result:false to failed', () async {
      Future<ActionResult> finish(Map<String, dynamic> event) {
        final h = client.sendActionGoal(action, type, {});
        connection.events.add({'op': 'action_result', 'id': h.id, ...event});
        return h.result;
      }

      expect((await finish({'status': 5, 'result': true})).status, ActionStatus.canceled);
      expect((await finish({'status': 6, 'result': true})).status, ActionStatus.aborted);
      expect((await finish({'status': 2, 'result': true})).status, ActionStatus.unknown);
      final rejected = await finish({'status': 0, 'result': false, 'values': 'Goal was rejected'});
      expect(rejected.status, ActionStatus.failed);
      expect(rejected.error, 'Goal was rejected');
    });

    test('a rosbridge error status with the goal id fails the goal', () async {
      final handle = client.sendActionGoal(action, type, {});
      connection.events.add({'op': 'status', 'level': 'error', 'id': handle.id, 'msg': 'Unknown action type'});
      final result = await handle.result;
      expect(result.status, ActionStatus.failed);
      expect(result.error, 'Unknown action type');
    });

    test('cancel sends cancel_action_goal once, and nothing after the goal finished', () async {
      final handle = client.sendActionGoal(action, type, {});
      handle.cancel();
      handle.cancel();
      final cancel = connection.sent.where((m) => m['op'] == 'cancel_action_goal').toList();
      expect(cancel, hasLength(1));
      expect(cancel.single['id'], handle.id);
      expect(cancel.single['action'], action);

      connection.events.add({'op': 'action_result', 'id': handle.id, 'status': 5, 'result': true});
      expect((await handle.result).status, ActionStatus.canceled);

      final finished = client.sendActionGoal(action, type, {});
      connection.events.add({'op': 'action_result', 'id': finished.id, 'status': 4, 'result': true});
      await finished.result;
      finished.cancel();
      expect(connection.sent.where((m) => m['op'] == 'cancel_action_goal'), hasLength(1));
    });

    test('fails when the connection closes before a result', () async {
      final handle = client.sendActionGoal(action, type, {});
      connection.close();
      final result = await handle.result.timeout(const Duration(seconds: 1));
      expect(result.status, ActionStatus.failed);
    });

    test('fails immediately when sending throws or the connection is already closed', () async {
      final throwing = _ThrowingConnection();
      final handle = RosClient(throwing).sendActionGoal(action, type, {});
      expect((await handle.result).status, ActionStatus.failed);

      connection.close();
      final afterClose = client.sendActionGoal(action, type, {});
      expect((await afterClose.result).status, ActionStatus.failed);
      expect(connection.sent.where((m) => m['op'] == 'send_action_goal'), isEmpty);
    });

    test('dispose stops following goals without cancelling them on the robot', () async {
      final handle = client.sendActionGoal(action, type, {});
      client.dispose();
      expect((await handle.result).status, ActionStatus.failed);
      expect(connection.sent.where((m) => m['op'] == 'cancel_action_goal'), isEmpty);
    });
  });
}

class _ThrowingConnection extends FakeConnection {
  @override
  void send(Map<String, dynamic> message) => throw StateError('Connection closed');
}
