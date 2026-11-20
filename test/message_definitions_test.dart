import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/dds/custom_interfaces.dart';
import 'package:ros_tester/dds/direct_connection.dart';
import 'package:ros_tester/message_definitions_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dds_cdr_test.dart' show bundled;
import 'direct_connection_test.dart' show FakeDds;

const statusMsg = 'std_msgs/Header header\nuint8 MODE_AUTO=1\nuint8 mode\nfloat32[] values\nstring label';

void main() {
  test('names and definitions are checked before saving', () {
    expect(interfaceName('my_robot_msgs/Status'), 'my_robot_msgs/msg/Status');
    expect(interfaceName('my_robot_msgs/srv/SetMode'), 'my_robot_msgs/srv/SetMode');
    expect(interfaceName('Status'), isNull);
    expect(interfaceName('my_robot_msgs/msg/status'), isNull);
    expect(baseInterface('my_robot_msgs/srv/SetMode_Request'), 'my_robot_msgs/srv/SetMode');
    expect(baseInterface('my_robot_msgs/action/Dock_SendGoal_Request'), 'my_robot_msgs/action/Dock');

    final known = bundled();
    final ok = checkDefinition('my_robot_msgs/msg/Status', statusMsg, known);
    expect((ok.ok, ok.fields), (true, 4));
    final missing = checkDefinition('my_robot_msgs/msg/Report', 'Status status\nPart[] parts', known);
    expect(missing.missing, ['my_robot_msgs/msg/Part', 'my_robot_msgs/msg/Status']);
    expect(checkDefinition('my_robot_msgs/srv/SetMode', 'uint8 mode', known).error, contains('"---"'));
    expect(checkDefinition('my_robot_msgs/srv/SetMode', 'uint8 mode\n---\nbool ok', known).ok, isTrue);
    expect(checkDefinition('my_robot_msgs/msg/Bad', 'this is not a field line!', known).error, isNotNull);
  });

  testWidgets('adding a definition makes the robot\'s custom topic readable at once', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final dds = FakeDds()..addRemote('rt/status', 'my_robot_msgs::msg::dds_::Status_');
    // Created outside the fake clock so the session's polling timer really runs.
    final session = (await tester.runAsync(() async => DirectRosSession(dds, 1, CdrCodec(bundled()))))!;
    final ros = session.connect();
    final events = <Map<String, dynamic>>[];
    final sub = ros.messages.listen(events.add);
    addTearDown(() async {
      await sub.cancel();
      session.close();
    });

    // A robot-side encoder that knows the type, to produce the samples.
    final robot = CdrCodec(bundled()..add('my_robot_msgs/msg/Status', statusMsg));
    final sample = robot.encode('my_robot_msgs/msg/Status', {'mode': 1, 'values': [0.5, 1.5], 'label': 'dock'});

    ros.send({'op': 'subscribe', 'topic': '/status'});
    await tester.runAsync(() async {
      dds.inject('rt/status', sample);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    expect(events.where((e) => e['op'] == 'publish'), isEmpty);
    expect(events.last['msg'], contains('Message definitions'));

    await tester.pumpWidget(MaterialApp(home: MessageDefinitionsPage(session: session)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('unknown-my_robot_msgs/msg/Status')), findsOneWidget);

    await tester.tap(find.descendant(of: find.byKey(const Key('unknown-my_robot_msgs/msg/Status')), matching: find.text('Add')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('definition-name'))).controller!.text,
        'my_robot_msgs/msg/Status'); // name prefilled
    await tester.enterText(find.byKey(const Key('definition-text')), statusMsg);
    await tester.pump();
    expect(find.text('4 fields, ready to use'), findsOneWidget);
    await tester.tap(find.byKey(const Key('save-definition')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('definition-my_robot_msgs/msg/Status')), findsOneWidget);
    expect(find.byKey(const Key('unknown-my_robot_msgs/msg/Status')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('ros2_custom_interfaces')!), {'my_robot_msgs/msg/Status': statusMsg});

    await tester.runAsync(() async {
      dds.inject('rt/status', sample);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    final msg = events.lastWhere((e) => e['op'] == 'publish')['msg'] as Map;
    expect((msg['mode'], msg['label']), (1, 'dock'));
    expect(msg['values'], [0.5, 1.5]);
  });

  testWidgets('saved definitions are loaded for the next connection', (tester) async {
    SharedPreferences.setMockInitialValues({'ros2_custom_interfaces': jsonEncode({'my_robot_msgs/msg/Status': statusMsg})});
    final saved = await loadCustomInterfaces();
    final interfaces = bundled();
    saved.forEach(interfaces.add);
    expect(interfaces.has('my_robot_msgs/msg/Status'), isTrue);

    await tester.pumpWidget(MaterialApp(home: MessageDefinitionsPage(bundled: bundled())));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('4 fields'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('None yet.'), findsOneWidget);
    expect(await loadCustomInterfaces(), isEmpty);
  });
}
