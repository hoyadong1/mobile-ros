import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';
import 'package:ros_tester/zenoh/zenoh_protocol.dart';
import 'dds_cdr_test.dart' show bundled;

// Tokens and keys as captured from a ROS 2 Jazzy TurtleBot3 + Nav2 simulation on rmw_zenoh.
const zid = '9af1aafc781a8c4dadfc184b7a33bf2c';
const odomHash = 'RIHS01_3cc97dc7fb7502f8714462c526d369e35b603cfc34d946e3f2eda2766dfec6e0';
const twistHash = 'RIHS01_9c45bf16fe0983d80e3cfe750d6835843d265a9a6c46bd2e609fcddde6fb8d2a';
const mapHash = 'RIHS01_8d348150c12913a31ee0ec170fbf25089e4745d17035792a1ba94d6f0bc0cfc7';
const tokens = [
  '@ros2_lv/0/$zid/61/61/NN/%/%/amcl',
  '@ros2_lv/0/e85f16b06c67dc0ecb92c8f58b6d6252/0/0/NN/%/%/ros_gz_bridge',
  '@ros2_lv/0/e85f16b06c67dc0ecb92c8f58b6d6252/0/14/MP/%/%/ros_gz_bridge/%odom/nav_msgs::msg::dds_::Odometry_/$odomHash/::,10:,:,:,,',
  '@ros2_lv/0/$zid/7/364/MS/%/%/controller_server/%odom/nav_msgs::msg::dds_::Odometry_/$odomHash/::,:,:,:,,',
  '@ros2_lv/0/e85f16b06c67dc0ecb92c8f58b6d6252/0/18/MS/%/%/ros_gz_bridge/%cmd_vel/geometry_msgs::msg::dds_::Twist_/$twistHash/::,10:,:,:,,',
  '@ros2_lv/0/$zid/43/153/MP/%/%/map_server/%map/nav_msgs::msg::dds_::OccupancyGrid_/$mapHash/:1:,1:,:,:,,',
  '@ros2_lv/0/$zid/206/510/SS/%/%/bt_navigator/%navigate_to_pose%_action%send_goal/nav2_msgs::action::dds_::NavigateToPose_SendGoal_/RIHS01_aa/::,10:,:,:,,',
  '@ros2_lv/0/$zid/206/515/SS/%/%/bt_navigator/%navigate_to_pose%_action%get_result/nav2_msgs::action::dds_::NavigateToPose_GetResult_/RIHS01_bb/::,10:,:,:,,',
  '@ros2_lv/0/$zid/206/514/SS/%/%/bt_navigator/%navigate_to_pose%_action%cancel_goal/action_msgs::srv::dds_::CancelGoal_/RIHS01_cc/::,10:,:,:,,',
  '@ros2_lv/0/$zid/206/512/MP/%/%/bt_navigator/%navigate_to_pose%_action%feedback/nav2_msgs::action::dds_::NavigateToPose_FeedbackMessage_/RIHS01_dd/::,10:,:,:,,',
  '@ros2_lv/0/$zid/43/160/SS/%/%/map_server/%map_server%get_state/lifecycle_msgs::srv::dds_::GetState_/RIHS01_ee/::,10:,:,:,,',
];

bool keyMatches(String selector, String key) {
  final s = selector.split('/'), k = key.split('/');
  bool go(int i, int j) {
    if (i == s.length) return j == k.length;
    if (s[i] == '**') return List.generate(k.length - j + 1, (n) => go(i + 1, j + n)).any((x) => x);
    if (j == k.length) return false;
    return (s[i] == '*' || s[i] == k[j]) && go(i + 1, j + 1);
  }
  return go(0, 0);
}

class FakeZenoh implements ZenohBackend {
  FakeZenoh(this.tokens);
  final List<String> tokens;
  final events = <ZenohEvent>[];
  final subs = <int, ({String key, bool liveliness, bool history})>{};
  final puts = <(String, Uint8List, Uint8List)>[];
  final queries = <int, (String, Uint8List?, Uint8List?)>{};
  /// Answers queries by key: replies to send (or null for no reply).
  final responders = <String, List<ZenohEvent> Function(int id, Uint8List? payload)>{};
  int _next = 0;
  bool closed = false;

  @override
  String get zid => 'app';
  @override
  int subscribe(String keyexpr, {bool liveliness = false, bool history = false}) {
    final id = _next++;
    subs[id] = (key: keyexpr, liveliness: liveliness, history: history);
    if (liveliness && history) {
      for (final t in tokens) {
        if (keyMatches(keyexpr, t)) events.add(ZenohEvent(ZenohEvent.alive, id, key: t));
      }
    }
    return id;
  }

  @override
  void unsubscribe(int id) => subs.remove(id);
  @override
  void put(String key, Uint8List payload, Uint8List attachment) => puts.add((key, payload, attachment));
  @override
  int query(String key, {Uint8List? payload, Uint8List? attachment, Duration? timeout, bool liveliness = false}) {
    final id = _next++;
    queries[id] = (key, payload, attachment);
    final responder = responders.entries.where((r) => key.startsWith(r.key)).firstOrNull?.value;
    if (responder != null) {
      Future<void>.delayed(const Duration(milliseconds: 5), () {
        events.addAll(responder(id, payload));
        events.add(ZenohEvent(ZenohEvent.queryDone, id));
      });
    }
    return id;
  }

  /// The robot publishes [payload] on [key].
  void publish(String key, Uint8List payload) {
    for (final e in subs.entries) {
      if (!e.value.liveliness && keyMatches(e.value.key, key)) {
        events.add(ZenohEvent(ZenohEvent.sample, e.key, key: key, payload: payload));
      }
    }
  }

  final declared = <int, String>{};
  @override
  int declareToken(String key) {
    final id = _next++;
    declared[id] = key;
    return id;
  }

  @override
  void undeclareToken(int id) => declared.remove(id);

  @override
  ZenohEvent? poll() => events.isEmpty ? null : events.removeAt(0);
  @override
  void close() => closed = true;
}

Future<Map<String, dynamic>> next(ZenohRosConnection c, bool Function(Map<String, dynamic>) test) =>
    c.messages.firstWhere(test).timeout(const Duration(seconds: 2));

void main() {
  final codec = CdrCodec(bundled());
  late FakeZenoh fake;
  late ZenohRosSession session;
  late ZenohRosConnection ros;

  setUp(() async {
    fake = FakeZenoh(tokens);
    session = await ZenohRosSession.open(router: 'robot', backend: fake, interfaces: bundled());
    ros = session.connect();
  });
  tearDown(() => session.close());

  group('protocol', () {
    test('parses rmw_zenoh tokens', () {
      final e = ZenohEntity.parse(tokens[2])!;
      expect(e.kind, ZenohEntityKind.publisher);
      expect((e.node, e.name, e.rosType), ('/ros_gz_bridge', '/odom', 'nav_msgs/msg/Odometry'));
      expect(e.dataKey, '0/odom/nav_msgs::msg::dds_::Odometry_/$odomHash');
      expect(e.transientLocal, isFalse);
      expect(ZenohEntity.parse(tokens[5])!.transientLocal, isTrue, reason: '/map is latched');
      final action = ZenohEntity.parse(tokens[6])!;
      expect((action.name, action.rosType),
          ('/navigate_to_pose/_action/send_goal', 'nav2_msgs/action/NavigateToPose_SendGoal'));
      expect(ZenohEntity.parse('@ros2_lv/x'), isNull);
      expect(ZenohEntity.parse('0/odom/type/hash'), isNull);
    });

    test('keys, selectors, locators and attachments', () {
      expect(zenohTopicSelector(0, '/robot1/odom'), '0/robot1/odom/*/*');
      expect(keyMatches('0/odom/*/*', '0/odom/nav_msgs::msg::dds_::Odometry_/$odomHash'), isTrue);
      expect(keyMatches('0/odom/*/*', '0/odom/filtered/nav_msgs::msg::dds_::Odometry_/$odomHash'), isFalse);
      expect(zenohLocator('192.168.0.10'), 'tcp/192.168.0.10:7447');
      expect(zenohLocator('robot:7448'), 'tcp/robot:7448');
      expect(zenohLocator('tcp/robot:7447'), 'tcp/robot:7447');
      final gid = Uint8List.fromList(List.generate(16, (i) => i));
      final a = zenohAttachment(9087, 1794462698332690994, gid);
      expect(a.length, 33);
      expect(a.sublist(0, 2), [0x7f, 0x23]);
      expect(a[16], 16);
      final (seq, time, back) = parseZenohAttachment(a)!;
      expect((seq, time), (9087, 1794462698332690994));
      expect(back, gid);
    });
  });

  test('opening without a robot on the router fails with an explanation', () async {
    await expectLater(
      ZenohRosSession.open(router: 'robot', backend: FakeZenoh(const []), interfaces: bundled(),
          discoveryTimeout: const Duration(milliseconds: 100)),
      throwsA(isA<StateError>().having((e) => e.message, 'message', contains('rmw_zenoh_cpp'))),
    );
  });

  test('rosapi answers from the graph', () async {
    final topics = await ros.call('/rosapi/topics');
    expect(topics['topics'], containsAll(['/odom', '/cmd_vel', '/map']));
    final i = (topics['topics'] as List).indexOf('/odom');
    expect(topics['types'][i], 'nav_msgs/msg/Odometry');
    expect((await ros.call('/rosapi/nodes'))['nodes'], ['/amcl', '/ros_gz_bridge']);
    expect((await ros.call('/rosapi/action_servers'))['action_servers'], ['/navigate_to_pose']);
    expect((await ros.call('/rosapi/publishers', {'topic': '/odom'}))['publishers'], ['/ros_gz_bridge']);
    expect((await ros.call('/rosapi/services'))['services'], contains('/map_server/get_state'));
  });

  test('subscribe decodes samples of the topic only; latched topics ask for history', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom', 'id': 'a'});
    ros.send({'op': 'subscribe', 'topic': '/map', 'id': 'b'});
    final odomSub = fake.subs.values.firstWhere((s) => s.key.startsWith('0/odom'));
    expect(odomSub.key, '0/odom/*/*');
    expect(odomSub.history, isFalse);
    expect(fake.subs.values.firstWhere((s) => s.key.startsWith('0/map')).history, isTrue);

    final got = next(ros, (m) => m['op'] == 'publish' && m['topic'] == '/odom');
    fake.publish('0/odom/nav_msgs::msg::dds_::Odometry_/$odomHash',
        codec.encode('nav_msgs/msg/Odometry', {'pose': {'pose': {'position': {'x': 1.5}}}}));
    expect((await got)['msg']['pose']['pose']['position']['x'], 1.5);

    // Publishers count subscribers from tokens (Nav2's /plan sends nothing without one).
    expect(fake.declared.values, contains(
        '@ros2_lv/0/app/0/1/MS/%/%/mobile_ros/%odom/nav_msgs::msg::dds_::Odometry_/$odomHash/::,10:,:,:,,'));
    ros.send({'op': 'unsubscribe', 'topic': '/odom', 'id': 'a'});
    expect(fake.subs.values.where((s) => s.key.startsWith('0/odom')), isEmpty);
    expect(fake.declared.values.where((t) => t.contains('%odom')), isEmpty, reason: 'token withdrawn');
    expect(fake.declared.values, contains('@ros2_lv/0/app/0/0/NN/%/%/mobile_ros'), reason: 'the app is a node');
  });

  test('a latched publisher seen after subscribing gets the subscription its history', () async {
    // Subscribed before the graph shows the publisher (as right after connecting to a busy fleet).
    ros.send({'op': 'subscribe', 'topic': '/map2', 'id': 'm'});
    expect(fake.subs.values.where((s) => s.key.startsWith('0/map2')).single.history, isFalse);
    final graph = fake.subs.entries.firstWhere((e) => e.value.liveliness).key;
    fake.events.add(ZenohEvent(ZenohEvent.alive, graph,
        key: '@ros2_lv/0/$zid/43/160/MP/%/%/map_server/%map2/nav_msgs::msg::dds_::OccupancyGrid_/$mapHash/:1:,1:,:,:,,'));
    for (var i = 0; i < 20 && !fake.subs.values.any((s) => s.key.startsWith('0/map2') && s.history); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final subs = fake.subs.values.where((s) => s.key.startsWith('0/map2')).toList();
    expect(subs, hasLength(1), reason: 'the plain subscription is replaced, not doubled');
    expect(subs.single.history, isTrue);
  });

  test('throttled subscriptions pass only the newest sample', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom', 'throttle_rate': 1000});
    final xs = <double>[];
    final sub = ros.messages.listen((m) => xs.add((m['msg']['pose']['pose']['position']['x'] as num).toDouble()));
    for (final x in [0.1, 0.2, 0.3]) {
      fake.publish('0/odom/nav_msgs::msg::dds_::Odometry_/$odomHash',
          codec.encode('nav_msgs/msg/Odometry', {'pose': {'pose': {'position': {'x': x}}}}));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    expect(xs, [0.3]);
  });

  test('publish uses the robot subscriber\'s key and type hash, with a growing sequence number', () async {
    ros.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/Twist'});
    for (var i = 0; i < 2; i++) {
      ros.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {'linear': {'x': 0.2}}});
    }
    expect(fake.puts, hasLength(2));
    final (key, payload, attachment) = fake.puts.last;
    expect(key, '0/cmd_vel/geometry_msgs::msg::dds_::Twist_/$twistHash');
    expect(codec.decode('geometry_msgs/msg/Twist', payload)['linear']['x'], 0.2);
    expect(parseZenohAttachment(attachment)!.$1, 1);
    expect(parseZenohAttachment(fake.puts.first.$3)!.$3, parseZenohAttachment(attachment)!.$3,
        reason: 'one GID per publisher');

    final error = next(ros, (m) => m['op'] == 'status');
    ros.send({'op': 'advertise', 'topic': '/nobody_listens', 'type': 'std_msgs/String'});
    ros.send({'op': 'publish', 'topic': '/nobody_listens', 'msg': {'data': 'x'}});
    expect((await error)['msg'], contains('Nothing on the robot uses /nobody_listens'));
  });

  test('a service call is a query on the server key, with the reply decoded', () async {
    fake.responders['0/map_server/get_state/'] = (id, payload) {
      expect(payload, isNotNull);
      return [
        ZenohEvent(ZenohEvent.reply, id, payload: codec.encode('lifecycle_msgs/srv/GetState_Response', {
          'current_state': {'id': 3, 'label': 'active'},
        })),
      ];
    };
    final reply = await ros.call('/map_server/get_state');
    expect(reply['current_state']['label'], 'active');
    final (key, _, attachment) = fake.queries.values.single;
    expect(key, '0/map_server/get_state/lifecycle_msgs::srv::dds_::GetState_/RIHS01_ee');
    expect(attachment!.length, 33);

    await expectLater(ros.call('/no/such/service'), throwsStateError);
    fake.responders['0/map_server/get_state/'] = (id, _) => [];
    await expectLater(ros.call('/map_server/get_state'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No reply'))));
  });

  test('an action goal: send_goal, feedback for this goal only, then get_result', () async {
    Uint8List? uuid;
    fake.responders['0/navigate_to_pose/_action/send_goal/'] = (id, payload) {
      final req = codec.decode('nav2_msgs/action/NavigateToPose_SendGoal_Request', payload!);
      uuid = Uint8List.fromList((req['goal_id']['uuid'] as List).cast<int>());
      expect(req['goal']['pose']['pose']['position']['x'], 2.0);
      return [ZenohEvent(ZenohEvent.reply, id,
          payload: codec.encode('nav2_msgs/action/NavigateToPose_SendGoal_Response', {'accepted': true}))];
    };
    final result = Completer<void>();
    fake.responders['0/navigate_to_pose/_action/get_result/'] = (id, _) {
      // Feedback for another goal first, then for this one, then the result.
      for (final goal in [Uint8List(16), uuid!]) {
        fake.publish('0/navigate_to_pose/_action/feedback/nav2_msgs::action::dds_::NavigateToPose_FeedbackMessage_/RIHS01_dd',
            codec.encode('nav2_msgs/action/NavigateToPose_FeedbackMessage', {
              'goal_id': {'uuid': goal}, 'feedback': {'distance_remaining': goal == uuid ? 1.5 : 9.0},
            }));
      }
      result.complete();
      return [ZenohEvent(ZenohEvent.reply, id,
          payload: codec.encode('nav2_msgs/action/NavigateToPose_GetResult_Response', {'status': 4}))];
    };
    final events = <Map<String, dynamic>>[];
    final sub = ros.messages.listen(events.add);
    ros.send({'op': 'send_action_goal', 'id': 'g1', 'action': '/navigate_to_pose',
      'action_type': 'nav2_msgs/action/NavigateToPose', 'feedback': true,
      'args': {'pose': {'header': {'frame_id': 'map'}, 'pose': {'position': {'x': 2.0}}}}});
    await next(ros, (m) => m['op'] == 'action_result');
    await sub.cancel();
    final feedback = events.where((m) => m['op'] == 'action_feedback').toList();
    expect(feedback.single['values']['distance_remaining'], 1.5);
    final r = events.singleWhere((m) => m['op'] == 'action_result');
    expect((r['id'], r['status'], r['result']), ('g1', 4, true));
  });

  test('an unknown action fails as an action result', () async {
    final r = next(ros, (m) => m['op'] == 'action_result');
    ros.send({'op': 'send_action_goal', 'id': 'x', 'action': '/fly', 'action_type': 'a/action/B', 'args': {}});
    final result = await r;
    expect(result['result'], isFalse);
    expect(result['values'], contains('not available'));
  });

  test('closing a view unsubscribes; closing the owning view closes the session', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    final before = fake.subs.length;
    ros.close();
    expect(fake.subs.length, before - 1);
    expect(fake.closed, isFalse);
    session.connect(ownsSession: true).close();
    expect(fake.closed, isTrue);
  });
}
