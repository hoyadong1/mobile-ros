import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/background_service.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/routines.dart';
import 'support/fake_ros_connection.dart';

class FakePresence implements BackgroundPresence {
  final shown = <(String, String, bool)>[];
  var hidden = 0;
  final _actions = StreamController<String>.broadcast();
  void press(String id) => _actions.add(id);
  @override
  Stream<String> get actions => _actions.stream;
  @override
  Future<void> show({required String title, required String text, bool stoppable = false}) async =>
      shown.add((title, text, stoppable));
  @override
  Future<void> hide() async => hidden++;
}

void main() {
  test('the notification says what is running, or what runs next, or nothing', () {
    final now = DateTime(2026, 11, 14, 9);
    expect(presenceFor(running: const [], next: null, now: now), isNull, reason: 'not connected');
    final idle = presenceFor(running: const [], next: null, now: now, connectedTo: '172.30.1.60:9090')!;
    expect((idle.title, idle.text, idle.stoppable), ('172.30.1.60:9090', 'Connected · tap to open', true));
    final named = presenceFor(running: const [], next: null, now: now, connectedTo: 'TurtleBot3', battery: '76 %')!;
    expect(named.title, 'TurtleBot3 · 76 %', reason: 'the robot by name, with its battery');
    final next = presenceFor(running: const [], next: ('', '순찰', DateTime(2026, 11, 14, 14, 5)), now: now,
        connectedTo: 'r')!;
    expect((next.title, next.text, next.stoppable), ('r', 'Next: 순찰 at 14:05', true));
    final tomorrow = presenceFor(running: const [], next: ('robot1', '순찰', DateTime(2026, 11, 15, 7)), now: now,
        connectedTo: 'r')!;
    expect(tomorrow.text, 'Next: 순찰 at 11/15 07:00');
    final run = presenceFor(running: const [('', '순찰', 'Round 2 of 5 · Go to a saved place · 부엌 (1/3)')],
        next: ('', '순찰', DateTime(2026, 11, 14, 14)), now: now, connectedTo: 'r')!;
    expect((run.title, run.text, run.stoppable), ('Running 순찰', 'Round 2 of 5 · Go to a saved place · 부엌 (1/3)', true));
  });

  testWidgets('a running routine shows in the notification, whose Stop stops it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final robot = FakeConnection();
    final presence = FakePresence();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: 'robot', port: '9090', connection: robot,
        connectionFactory: (_, _) => FakeConnection(), presence: presence)));
    await tester.pump();
    final state = tester.state(find.byType(MainPage)) as dynamic;
    final session = state.session;
    await session.routines.load();
    await session.routines.save(Routine(id: 'p', name: '순찰',
        steps: [const RoutineStep.call(SkillCall('get_status'))], repeat: 0, pauseSeconds: 30));
    final agent = state.robots[0].routineAgent;
    unawaited(agent.runRoutine(session.routines.find('순찰')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(presence.shown.last.$1, 'Running 순찰');
    expect(presence.shown.last.$2, startsWith('Round 1'));
    expect(presence.shown.last.$3, isTrue);
    presence.press('stop');
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200)); // the wait between rounds notices the stop
    }
    expect(agent.progress, isNull);
    expect(presence.shown.last.$1, 'robot:9090', reason: 'still connected: back to the plain notice');
    await tester.pumpWidget(const SizedBox());
    robot.close();
  });

  testWidgets('disposing a workspace with an active routine does not reshow its notification', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final robot = FakeConnection();
    final presence = FakePresence();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: 'robot', port: '9090', connection: robot,
      connectionFactory: (_, _) => FakeConnection(), presence: presence)));
    await tester.pump();
    final state = tester.state(find.byType(MainPage)) as dynamic;
    final routine = Routine(id: 'close-test', name: 'Close test',
      steps: [const RoutineStep.call(SkillCall('get_status'))], repeat: 0, pauseSeconds: 30);
    await state.session.routines.load();
    final Future<dynamic> running = state.robots[0].routineAgent.runRoutine(routine);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(presence.shown.last.$1, 'Running Close test');
    final shown = presence.shown.length;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    await running;
    expect(presence.hidden, 1);
    expect(presence.shown, hasLength(shown), reason: 'routine disposal must not show the old notice again');
    expect(tester.takeException(), isNull);
  });
}
