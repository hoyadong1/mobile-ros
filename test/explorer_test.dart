import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/explorer_page.dart';
import 'support/fake_ros_connection.dart';

FakeConnection robot() => FakeConnection()
  ..serviceResponses['/rosapi/topics'] = {
    'topics': ['/odom', '/camera/image_raw', '/cmd_vel'],
    'types': ['nav_msgs/msg/Odometry', 'sensor_msgs/msg/Image', 'geometry_msgs/msg/Twist'],
  }
  ..serviceResponses['/rosapi/nodes'] = {'nodes': ['/turtlebot3_diff_drive', '/camera_driver']}
  ..serviceResponses['/rosapi/services'] = {'services': ['/reset', '/set_mode']}
  ..serviceResponses['/rosapi/node_details'] = {
    'publishing': ['/odom'], 'subscribing': ['/cmd_vel'], 'services': ['/reset']}
  ..serviceResponses['/rosapi/publishers'] = {'publishers': ['/turtlebot3_diff_drive']}
  ..serviceResponses['/rosapi/subscribers'] = {'subscribers': []}
  ..serviceResponses['/rosapi/service_type'] = {'type': 'demo_srvs/srv/SetMode'}
  ..serviceResponses['/rosapi/service_request_details'] = {'typedefs': [
    {'type': 'demo_srvs/SetModeRequest', 'fieldnames': ['mode', 'force'], 'fieldtypes': ['string', 'bool'],
      'fieldarraylen': [-1, -1], 'examples': ['', 'False'], 'constnames': [], 'constvalues': []},
  ]}
  ..serviceResponses['/set_mode'] = {'success': true, 'message': 'mode set'};

Future<FakeConnection> open(WidgetTester tester) async {
  final r = robot();
  addTearDown(r.close);
  await tester.pumpWidget(MaterialApp(home: ExplorerPage(ip: 'r', port: '9090', connectionFactory: (_, _) => r)));
  await tester.pumpAndSettle();
  return r;
}

void main() {
  test('long arrays and base64 strings are cut for display', () {
    final out = truncateForDisplay({'data': 'x' * 500, 'ranges': List.generate(360, (i) => i)}) as Map;
    expect(out['data'], endsWith('(500 chars)'));
    expect((out['ranges'] as List).length, 13);
    expect((out['ranges'] as List).last, '… 348 more (360 items)');
    expect(isHeavyType('sensor_msgs/msg/Image'), isTrue);
    expect(isHeavyType('nav_msgs/msg/Odometry'), isFalse);
  });

  testWidgets('one connection lists topics with types, nodes and services; search covers types', (tester) async {
    final r = await open(tester);
    expect(find.text('Topics 3'), findsOneWidget);
    expect(find.text('sensor_msgs/Image'), findsOneWidget, reason: 'types are shown');
    await tester.enterText(find.byKey(const Key('explorer-search')), 'twist');
    await tester.pump();
    expect(find.text('/cmd_vel'), findsOneWidget);
    expect(find.text('/odom'), findsNothing);
    expect(r.calls.map((c) => c.$1), containsAll(['/rosapi/topics', '/rosapi/nodes', '/rosapi/services']));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a heavy topic is throttled to 1 Hz and its preview is truncated', (tester) async {
    final r = await open(tester);
    await tester.tap(find.text('/camera/image_raw'));
    await tester.pumpAndSettle();
    final sub = r.sent.lastWhere((m) => m['op'] == 'subscribe');
    expect(sub['topic'], '/camera/image_raw');
    expect(sub['throttle_rate'], 1000);
    r.events.add({'op': 'publish', 'topic': '/camera/image_raw',
      'msg': {'width': 640, 'height': 480, 'encoding': 'rgb8', 'data': 'A' * 100000}});
    await tester.pump();
    await tester.pump();
    final shown = tester.widget<SelectableText>(find.byKey(const Key('topic-message'))).data!;
    expect(shown, contains('"width": 640'));
    expect(shown.length, lessThan(1000));
    expect(find.text('/turtlebot3_diff_drive'), findsOneWidget, reason: 'publisher chip');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(r.sent.last, predicate<Map>((m) => m['op'] == 'unsubscribe' && m['topic'] == '/camera/image_raw'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('node details link to topics', (tester) async {
    final r = await open(tester);
    await tester.tap(find.text('Nodes 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/turtlebot3_diff_drive'));
    await tester.pumpAndSettle();
    expect(find.text('PUBLISHES · 1'), findsOneWidget);
    await tester.tap(find.text('/odom'));
    await tester.pumpAndSettle();
    expect(r.sent.last, predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/odom' && m['throttle_rate'] == 20));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a service shows its type, pre-fills the request and shows the response', (tester) async {
    final r = await open(tester);
    await tester.tap(find.text('Services 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/set_mode'));
    await tester.pumpAndSettle();
    expect(find.text('demo_srvs/srv/SetMode'), findsOneWidget);
    final request = tester.widget<TextField>(find.byKey(const Key('service-request'))).controller!.text;
    expect(request, contains('"force": false'));
    await tester.enterText(find.byKey(const Key('service-request')), '{"mode": "OFFBOARD", "force": true}');
    await tester.tap(find.byKey(const Key('service-call')));
    await tester.pumpAndSettle();
    expect(r.calls.last.$1, '/set_mode');
    expect(r.calls.last.$2, {'mode': 'OFFBOARD', 'force': true});
    expect(tester.widget<SelectableText>(find.byKey(const Key('service-response'))).data, contains('mode set'));

    await tester.enterText(find.byKey(const Key('service-request')), '{"mode": 3}');
    await tester.tap(find.byKey(const Key('service-call')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const Key('service-response'))).data,
        startsWith('Request is not valid'), reason: 'checked against the request type before sending');
    await tester.pumpWidget(const SizedBox());
  });
}
