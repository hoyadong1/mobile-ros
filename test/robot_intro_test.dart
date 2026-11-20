import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/widgets/robot_intro.dart';

import 'support/fake_ros_connection.dart';

RobotSession session(FakeConnection c) => RobotSession(connection: c, ip: 'robot', port: '9090', namespace: '/robot1');

FakeConnection turtle() => FakeConnection()..serviceResponses['/rosapi/topics'] = {
  'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot1/scan', '/robot1/navigate_to_pose/_action/status',
    '/rosout', '/turtlebot3_node/x'],
  'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/LaserScan',
    'action_msgs/msg/GoalStatusArray', 'rcl_interfaces/msg/Log', 'std_msgs/msg/String'],
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the first meeting asks, remembers each answer, and is not offered again', (tester) async {
    final c = turtle();
    final s = session(c);
    final person = Memory('user-test');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (context) => Column(children: [
      RobotIntroCard(session: s),
      TextButton(onPressed: () => showModalBottomSheet<void>(context: context, isScrollControlled: true,
          builder: (_) => RobotIntroSheet(session: s, person: person)), child: const Text('open')),
    ])))));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-intro-card')), findsOneWidget);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Is that right?'), findsOneWidget, reason: 'it says what it thinks it is');
    await tester.tap(find.byKey(const Key('intro-choice-Not quite')));
    await tester.pumpAndSettle();
    expect(find.text('Sorry! What kind of robot am I?'), findsOneWidget);
    Future<void> say(String text) async {
      await tester.enterText(find.byKey(const Key('robot-intro-input')), text);
      await tester.tap(find.byKey(const Key('robot-intro-send')));
      await tester.pumpAndSettle();
    }
    await say('a delivery robot with a tray');
    await say('순돌이');
    expect(find.text('순돌이. I like it!'), findsOneWidget);
    await say('민수');
    await tester.tap(find.byKey(const Key('intro-choice-Patrol')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('robot-intro-skip'))); // how to talk: skipped
    await tester.pumpAndSettle();
    await say('stay away from the stairs');
    expect(find.textContaining('Nice to meet you, 민수! I am 순돌이.'), findsOneWidget);

    final m = s.memory;
    expect(m.profile(RobotPersona.kindKey), 'a delivery robot with a tray');
    expect(m.profile(RobotPersona.nameKey), '순돌이');
    expect(m.profile(RobotPersona.roleKey), 'Patrol');
    expect(m.profile(RobotPersona.toneKey), isNull);
    expect(m.ofKind('note').single.text, 'stay away from the stairs');
    expect(person.profile(RobotPersona.callPersonKey), '민수');
    expect(s.label, '순돌이');
    await tester.tap(find.byKey(const Key('robot-intro-done')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-intro-card')), findsNothing, reason: 'met once');

    // Kept on the phone: a new session for the same robot reads it back.
    final again = session(c);
    await again.memory.load();
    expect(again.label, '순돌이');
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    again.dispose();
    c.close();
  });

  testWidgets('"Not now" puts it off; the memory page edits, adds and forgets', (tester) async {
    final c = turtle();
    final s = session(c);
    final person = Memory('user-test-2');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RobotIntroCard(session: s))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('robot-intro-later')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-intro-card')), findsNothing);

    await tester.pumpWidget(MaterialApp(home: RobotMemoryPage(session: s, person: person)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-name')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memory-edit-field')), 'Sunny');
    await tester.tap(find.byKey(const Key('memory-edit-save')));
    await tester.pumpAndSettle();
    expect(s.label, 'Sunny');
    await tester.tap(find.byKey(const Key('memory-add-note')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memory-note-field')), 'charge before 6 pm');
    await tester.tap(find.byKey(const Key('memory-note-save')));
    await tester.pumpAndSettle();
    expect(find.text('charge before 6 pm'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('memory-forget')), 200);
    await tester.ensureVisible(find.byKey(const Key('memory-forget')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-forget')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-forget-confirm')));
    await tester.pumpAndSettle();
    expect(s.memory.items, isEmpty);
    expect(s.label, 'robot1');
    await tester.pumpWidget(const SizedBox());
    s.dispose();
    c.close();
  });
}
