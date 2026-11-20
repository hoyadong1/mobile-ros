import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/dds/ros_interfaces.dart';
import 'package:ros_tester/foxglove_connection.dart';

const _twistSchema = 'Vector3 linear\nVector3 angular\n'
    '================================================================================\n'
    'MSG: geometry_msgs/Vector3\nfloat64 x\nfloat64 y\nfloat64 z';

/// A foxglove_bridge on the other end of the socket: what the app sends is kept, the test speaks for it.
class FakeBridge {
  final toApp = StreamController<dynamic>();
  final fromApp = <Object>[];
  late final FoxgloveRosConnection app;
  // The bridge's own codec, knowing only what it advertises (the app must learn it from the schemas).
  final codec = CdrCodec(RosInterfaces({
    'geometry_msgs/msg/Twist': 'Vector3 linear\nVector3 angular',
    'geometry_msgs/msg/Vector3': 'float64 x\nfloat64 y\nfloat64 z',
    'std_srvs/srv/Trigger': '---\nbool success\nstring message',
  }));

  FakeBridge({List<String> capabilities = const ['clientPublish', 'services', 'connectionGraph']}) {
    app = FoxgloveRosConnection(toApp.stream, fromApp.add, CdrCodec(RosInterfaces({})));
    say({'op': 'serverInfo', 'name': 'foxglove_bridge', 'capabilities': capabilities, 'supportedEncodings': ['cdr']});
    say({'op': 'advertise', 'channels': []});
  }

  void say(Map<String, Object?> m) => toApp.add(jsonEncode(m));
  List<Map> get json => [for (final f in fromApp) if (f is String) jsonDecode(f) as Map];
  List<Uint8List> get binary => [for (final f in fromApp) if (f is Uint8List) f];

  void message(int subscriptionId, Uint8List payload) {
    final frame = Uint8List(13 + payload.length);
    frame[0] = 0x01;
    ByteData.sublistView(frame).setUint32(1, subscriptionId, Endian.little);
    frame.setRange(13, frame.length, payload);
    toApp.add(frame);
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('topics: learned from the bridge with their definitions, subscribed, read; and published back', () async {
    final bridge = FakeBridge();
    final app = bridge.app;
    addTearDown(app.close);
    await app.ready;
    bridge.say({'op': 'advertise', 'channels': [
      {'id': 7, 'topic': '/cmd_vel', 'encoding': 'cdr', 'schemaName': 'geometry_msgs/msg/Twist',
        'schema': _twistSchema, 'schemaEncoding': 'ros2msg'},
    ]});
    await settle();
    expect(await app.call('/rosapi/topics'), {'topics': ['/cmd_vel'], 'types': ['geometry_msgs/msg/Twist']});

    final got = <Map>[];
    app.messages.where((m) => m['op'] == 'publish').listen(got.add);
    app.send({'op': 'subscribe', 'topic': '/cmd_vel', 'type': 'geometry_msgs/Twist'});
    final sub = bridge.json.last;
    expect(sub['op'], 'subscribe');
    final subscription = sub['subscriptions'][0];
    expect(subscription['channelId'], 7);
    bridge.message(subscription['id'] as int, bridge.codec.encode('geometry_msgs/msg/Twist', {
      'linear': {'x': 0.5, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': -0.25}}));
    await settle();
    expect(got.single['msg']['linear']['x'], 0.5);
    expect(got.single['msg']['angular']['z'], -0.25);

    app.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
    expect(bridge.json.last, {'op': 'advertise', 'channels': [
      {'id': 1, 'topic': '/cmd_vel', 'encoding': 'cdr', 'schemaName': 'geometry_msgs/msg/Twist'}]});
    app.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {'linear': {'x': 0.2}, 'angular': {'z': 0.1}}});
    final frame = bridge.binary.last;
    expect(frame[0], 0x01);
    expect(ByteData.sublistView(frame).getUint32(1, Endian.little), 1);
    final sent = bridge.codec.decode('geometry_msgs/msg/Twist', Uint8List.sublistView(frame, 5));
    expect((sent['linear']['x'], sent['angular']['z']), (0.2, 0.1));
  });

  test('a topic advertised after the subscription is picked up; throttled topics deliver the newest', () async {
    final bridge = FakeBridge();
    final app = bridge.app;
    addTearDown(app.close);
    await app.ready;
    final got = <Map>[];
    app.messages.where((m) => m['op'] == 'publish').listen(got.add);
    app.send({'op': 'subscribe', 'topic': '/odom_like', 'type': 'geometry_msgs/Twist', 'throttle_rate': 200});
    expect(bridge.json.where((m) => m['op'] == 'subscribe'), isEmpty, reason: 'not advertised yet');
    bridge.say({'op': 'advertise', 'channels': [{'id': 3, 'topic': '/odom_like', 'encoding': 'cdr',
      'schemaName': 'geometry_msgs/msg/Twist', 'schema': _twistSchema}]});
    await settle();
    final id = bridge.json.last['subscriptions'][0]['id'] as int;
    for (final x in [1.0, 2.0, 3.0]) {
      bridge.message(id, bridge.codec.encode('geometry_msgs/msg/Twist', {'linear': {'x': x}}));
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(got.map((m) => m['msg']['linear']['x']), [3.0], reason: 'only the newest within the period');
  });

  test('services: called with CDR and answered; a failure is an error', () async {
    final bridge = FakeBridge();
    final app = bridge.app;
    addTearDown(app.close);
    await app.ready;
    bridge.say({'op': 'advertiseServices', 'services': [
      {'id': 4, 'name': '/reset_odom', 'type': 'std_srvs/srv/Trigger',
        'request': {'encoding': 'cdr', 'schemaName': 'std_srvs/srv/Trigger_Request', 'schemaEncoding': 'ros2msg', 'schema': ''},
        'response': {'encoding': 'cdr', 'schemaName': 'std_srvs/srv/Trigger_Response', 'schemaEncoding': 'ros2msg',
          'schema': 'bool success\nstring message'}},
    ]});
    await settle();
    expect((await app.call('/rosapi/services'))['services'], ['/reset_odom']);
    final answer = app.call('/reset_odom');
    await settle();
    final request = bridge.binary.last;
    final view = ByteData.sublistView(request);
    expect((request[0], view.getUint32(1, Endian.little)), (0x02, 4));
    final callId = view.getUint32(5, Endian.little);
    final payload = bridge.codec.encode('std_srvs/srv/Trigger_Response', {'success': true, 'message': 'done'});
    final reply = Uint8List(16 + payload.length);
    final rv = ByteData.sublistView(reply);
    reply[0] = 0x03;
    rv.setUint32(1, 4, Endian.little);
    rv.setUint32(5, callId, Endian.little);
    rv.setUint32(9, 3, Endian.little);
    reply.setRange(13, 16, utf8.encode('cdr'));
    reply.setRange(16, reply.length, payload);
    bridge.toApp.add(reply);
    expect(await answer, {'success': true, 'message': 'done'});

    final failing = app.call('/reset_odom');
    await settle();
    final failedId = ByteData.sublistView(bridge.binary.last).getUint32(5, Endian.little);
    bridge.say({'op': 'serviceCallFailure', 'serviceId': 4, 'callId': failedId, 'message': 'busy'});
    await expectLater(failing, throwsA(isA<StateError>()));
  });

  test('a bridge that does not accept client messages says so instead of driving silently', () async {
    final bridge = FakeBridge(capabilities: const []);
    final app = bridge.app;
    addTearDown(app.close);
    await app.ready;
    final errors = <String>[];
    app.messages.where((m) => m['op'] == 'status').listen((m) => errors.add('${m['msg']}'));
    app.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
    await settle();
    expect(errors.single, contains('clientPublish'));
  });

  test('ops sent before the hello wait for it; a re-advertised topic keeps flowing on its new channel', () async {
    final toApp = StreamController<dynamic>();
    final fromApp = <Object>[];
    final codec = CdrCodec(RosInterfaces({
      'geometry_msgs/msg/Twist': 'Vector3 linear\nVector3 angular',
      'geometry_msgs/msg/Vector3': 'float64 x\nfloat64 y\nfloat64 z',
    }));
    final app = FoxgloveRosConnection(toApp.stream, fromApp.add, codec);
    addTearDown(app.close);
    final errors = <String>[];
    app.messages.where((m) => m['op'] == 'status').listen((m) => errors.add('${m['msg']}'));
    // A screen opens and advertises at once, before the bridge has said it accepts client messages.
    app.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
    app.send({'op': 'subscribe', 'topic': '/scan_like', 'type': 'geometry_msgs/msg/Twist'});
    toApp.add(jsonEncode({'op': 'serverInfo', 'capabilities': ['clientPublish']}));
    toApp.add(jsonEncode({'op': 'advertise', 'channels': [{'id': 3, 'topic': '/scan_like', 'encoding': 'cdr',
      'schemaName': 'geometry_msgs/msg/Twist'}]}));
    await settle();
    await app.ready;
    expect(errors, isEmpty, reason: 'not refused for lack of a hello');
    final sent = [for (final f in fromApp) if (f is String) jsonDecode(f) as Map];
    expect(sent.any((m) => m['op'] == 'advertise'), isTrue);
    final first = sent.lastWhere((m) => m['op'] == 'subscribe')['subscriptions'][0];
    expect(first['channelId'], 3);

    // The publisher restarts: the bridge advertises a new channel, then drops the old one.
    toApp.add(jsonEncode({'op': 'advertise', 'channels': [{'id': 9, 'topic': '/scan_like', 'encoding': 'cdr',
      'schemaName': 'geometry_msgs/msg/Twist'}]}));
    toApp.add(jsonEncode({'op': 'unadvertise', 'channelIds': [3]}));
    await settle();
    final now = [for (final f in fromApp) if (f is String) jsonDecode(f) as Map];
    final moved = now.lastWhere((m) => m['op'] == 'subscribe')['subscriptions'][0];
    expect(moved['channelId'], 9);
    final got = <Map>[];
    app.messages.where((m) => m['op'] == 'publish').listen(got.add);
    final payload = codec.encode('geometry_msgs/msg/Twist', {'linear': {'x': 7.0}});
    final frame = Uint8List(13 + payload.length)..[0] = 0x01;
    ByteData.sublistView(frame).setUint32(1, moved['id'] as int, Endian.little);
    frame.setRange(13, frame.length, payload);
    toApp.add(frame);
    await settle();
    expect(got.single['msg']['linear']['x'], 7.0);
  });
}
