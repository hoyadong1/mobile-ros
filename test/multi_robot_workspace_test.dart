import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ros_connection.dart';

void main() {
  testWidgets('two-robot picker and Stop all fit a narrow screen', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
    };
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: 'robot', port: '9090',
      connection: connection, connectionFactory: (_, _) => connection)));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('robot-robot1')), findsOneWidget);
    expect(find.byKey(const Key('robot-robot2')), findsOneWidget);
    expect(find.byKey(const Key('stop-all')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('workspace selects either robot and Stop all sends zero velocity to both', (tester) async {
    SharedPreferences.setMockInitialValues({
      for (final name in ['robot1', 'robot2'])
        'robot_profile:robot:9090/$name': jsonEncode(RobotProfile.defaults(
          DriveType.differential, commandTopic: '/$name/cmd_vel').toJson()),
    });
    await tester.binding.setSurfaceSize(const Size(900, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': [
        '/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom',
      ],
      'types': [
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
      ],
    };
    await tester.pumpWidget(MaterialApp(home: MainPage(
      ip: 'robot', port: '9090', connection: connection,
      connectionFactory: (_, _) => connection,
    )));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    final first = find.byKey(const Key('robot-robot1'));
    final second = find.byKey(const Key('robot-robot2'));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(find.byKey(const Key('stop-all')), findsOneWidget);
    expect(tester.widget<ChoiceChip>(first).selected, isTrue);
    expect(find.byKey(const Key('home-doing')), findsOneWidget);

    // Opening control loads the saved profile into each robot's session controller.
    for (final (chip, summary) in [(first, 'summary-/robot1'), (second, 'summary-/robot2')]) {
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pump();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      // This robot's details are one tap away, in a sheet.
      await tester.ensureVisible(find.byKey(const Key('about-robot')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('about-robot')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(summary)), findsOneWidget);
      await tester.tapAt(const Offset(10, 10)); // close the sheet
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('tool-control')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('tool-control')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pageBack();
      await tester.pump(const Duration(milliseconds: 500));
    }

    connection.sent.clear();
    await tester.ensureVisible(find.byKey(const Key('stop-all')));
    await tester.tap(find.byKey(const Key('stop-all')));
    await tester.pump();
    expect(find.text('Stop requested for all robots.'), findsWidgets);
    for (final name in ['robot1', 'robot2']) {
      expect(connection.sent, contains(predicate<Map<String, dynamic>>((m) =>
        m['op'] == 'publish' && m['topic'] == '/$name/cmd_vel' &&
        (m['msg'] as Map)['linear']['x'] == 0 && (m['msg'] as Map)['angular']['z'] == 0)));
    }
    await tester.pumpWidget(const SizedBox());
  });
}
