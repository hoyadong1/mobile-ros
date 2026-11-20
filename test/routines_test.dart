import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/routine_scheduler.dart';
import 'package:ros_tester/routines.dart';
import 'package:ros_tester/routines_page.dart';
import 'support/fake_ros_connection.dart';

RoutineStep call(String name, [Map<String, Object?> args = const {}]) => RoutineStep.call(SkillCall(name, args));

/// Plans one fixed list of calls per instruction, in order.
class Scripted extends AgentBackend {
  Scripted(this.plans);
  final List<List<SkillCall>> plans;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: plans.removeAt(0));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('book', () {
    test('saves, reloads, and a routine with the same name replaces the old one', () async {
      final book = RoutineBook('robot:9090');
      await book.load();
      await book.save(Routine(id: 'a', name: ' 순찰 ', steps: [call('move', {'distance_m': 1.0})],
          schedules: const [RoutineSchedule(hour: 9, minute: 30, weekdays: {1, 3})]));
      await book.save(Routine(id: 'b', name: '순찰', steps: [call('rotate', {'angle_deg': 90.0})]));
      final again = RoutineBook('robot:9090');
      await again.load();
      expect(again.routines.single.id, 'b');
      expect(again.find('순찰')!.steps.single.call.toString(), 'rotate(angle_deg: 90.0)');
      expect(RoutineBook('other:9090').routines, isEmpty, reason: 'per robot');

      await again.save(Routine(id: 'c', name: '아침', steps: [call('stop')],
          schedules: const [RoutineSchedule(hour: 7, minute: 5, weekdays: {1, 2, 3, 4, 5}, enabled: false)]));
      final third = RoutineBook('robot:9090');
      await third.load();
      final s = third.find('아침')!.schedules.single;
      expect((s.hour, s.minute, s.enabled), (7, 5, false));
      expect(s.weekdays, {1, 2, 3, 4, 5});
    });

    test('nested routines expand in place; cycles, deep nesting and deleted steps are refused', () async {
      final book = RoutineBook('r');
      await book.save(Routine(id: 'a', name: 'A', steps: [call('move', {'distance_m': 1})]));
      await book.save(Routine(id: 'b', name: 'B', steps: [const RoutineStep.routine('a'), call('rotate', {'angle_deg': 90})]));
      await book.save(Routine(id: 'c', name: 'C', steps: [const RoutineStep.routine('b'), const RoutineStep.routine('a')]));
      expect(book.expand(book.byId('c')!).map((c) => c.name), ['move', 'rotate', 'move']);

      expect(() => book.save(Routine(id: 'a', name: 'A', steps: [const RoutineStep.routine('c')])),
          throwsA(isA<RoutineError>()), reason: 'A → C → B → A');
      expect(book.byId('a')!.steps.single.call?.name, 'move', reason: 'the refused change was not kept');

      expect(() => book.save(Routine(id: 'd', name: 'D', steps: [const RoutineStep.routine('c')])),
          throwsA(isA<RoutineError>()), reason: 'D → C → B → A is 4 deep');
      expect(book.byId('d'), isNull);

      expect(book.usersOf('a').map((r) => r.id), ['b', 'c']);
      await book.remove('a');
      expect(() => book.expand(book.byId('b')!), throwsA(isA<RoutineError>()));
    });
  });

  group('schedule', () {
    const weekdays = RoutineSchedule(hour: 9, minute: 0, weekdays: {1, 2, 3, 4, 5});
    final friday = DateTime(2026, 11, 13, 8, 0); // a Friday

    test('is due in its minute on its days, and knows when it runs next', () {
      expect(weekdays.dueAt(DateTime(2026, 11, 13, 9, 0, 40)), isTrue);
      expect(weekdays.dueAt(DateTime(2026, 11, 13, 9, 1)), isFalse);
      expect(weekdays.dueAt(DateTime(2026, 11, 14, 9, 0)), isFalse, reason: 'Saturday');
      expect(weekdays.nextAfter(friday), DateTime(2026, 11, 13, 9));
      expect(weekdays.nextAfter(DateTime(2026, 11, 13, 9, 30)), DateTime(2026, 11, 16, 9), reason: 'next Monday');
      expect(weekdays.copyWith(enabled: false).nextAfter(friday), isNull);
    });

    test('the scheduler starts a due routine once in its minute', () async {
      final book = RoutineBook('r');
      await book.save(Routine(id: 'p', name: '순찰', steps: [call('stop')], schedules: const [weekdays]));
      var now = DateTime(2026, 11, 13, 9, 0, 5);
      final started = <String>[];
      final scheduler = RoutineScheduler(book, clock: () => now, run: (r) async => started.add(r.name));
      expect(scheduler.check().map((r) => r.name), ['순찰']);
      now = DateTime(2026, 11, 13, 9, 0, 50);
      expect(scheduler.check(), isEmpty);
      now = DateTime(2026, 11, 13, 9, 1);
      expect(scheduler.check(), isEmpty);
      expect(started, ['순찰']);
      now = DateTime(2026, 11, 13, 10);
      expect(scheduler.next()!.$2, DateTime(2026, 11, 16, 9));
    });
  });

  group('agent', () {
    late FakeConnection robot;
    late DriveController drive;
    late NavigationController nav;
    late RoutineBook book;

    setUp(() async {
      robot = FakeConnection();
      final ros = RosClient(robot);
      drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
      nav = NavigationController(ros);
      book = RoutineBook('r');
      await book.load();
    });
    tearDown(() {
      drive.dispose();
      nav.dispose();
    });

    test('the manifest offers run_routine for saved names and save_routine', () async {
      await book.save(Routine(id: 'p', name: '순찰', steps: [call('stop')]));
      final agent = RobotAgent(drive: drive, nav: nav, backend: Scripted([]), routines: book);
      final m = agent.manifest();
      expect(m.skill('run_routine')!.params.single.values, ['순찰']);
      expect(m.skill('save_routine'), isNotNull);
      expect(m.describe(), contains('Saved routines: 순찰.'));
      expect(AgentManifest.build().skill('save_routine'), isNull);
    });

    test('"save what you just did" keeps the previous instruction\'s actions, not status or stop', () async {
      final agent = RobotAgent(drive: drive, nav: nav, routines: book, backend: Scripted([
        [const SkillCall('get_status'), const SkillCall('stop')],
        [const SkillCall('save_routine', {'name': '정지'})],
      ]));
      await agent.handle('상태 보고 멈춰');
      final r = await agent.handle('방금 한 거 저장해');
      expect(r.results.single.ok, isFalse, reason: 'nothing worth saving');

      await book.save(Routine(id: 'p', name: '순찰', steps: [call('stop')]));
      final agent2 = RobotAgent(drive: drive, nav: nav, routines: book, backend: Scripted([
        [const SkillCall('run_routine', {'name': '순찰'}), const SkillCall('save_routine', {'name': '두번 순찰'})],
      ]));
      final saved = await agent2.handle('순찰 돌고 이걸 두번 순찰로 저장해');
      expect(saved.ok, isTrue);
      expect(book.find('두번 순찰')!.steps.single.routineId, 'p', reason: 'a routine run is saved as a reference');
    });

    test('a routine repeats its rounds, with progress for each step, and saves how often to repeat', () async {
      await book.save(Routine(id: 'p', name: '순찰', steps: [call('get_status'), call('stop')], repeat: 3));
      final again = RoutineBook('r');
      await again.load();
      expect((again.find('순찰')!.repeat, repeatText(again.find('순찰')!)), (3, '3 times'));
      final agent = RobotAgent(drive: drive, nav: nav, backend: NoPlanner(), routines: book)
        ..describeStep = (c) => 'doing ${c.name}';
      final seen = <String>[];
      agent.addListener(() {
        final p = agent.progress;
        if (p != null && p.step > 0) seen.add('${p.round}/${p.rounds} ${p.step}/${p.steps} ${p.doing}');
      });
      final run = await agent.runRoutine(book.find('순찰')!);
      expect(run.ok, isTrue);
      expect(run.results.last.message, 'Ran "순찰" 3 times.');
      expect(seen.toSet(), {for (var r = 1; r <= 3; r++) ...['$r/3 1/2 doing get_status', '$r/3 2/2 doing stop']});
      expect(agent.progress, isNull, reason: 'cleared when done');
    });

    test('"until stopped" keeps going, waits between rounds, and a stop ends it at once', () async {
      await book.save(Routine(id: 'p', name: '순찰', steps: [call('get_status')], repeat: 0, pauseSeconds: 1));
      final agent = RobotAgent(drive: drive, nav: nav, backend: NoPlanner(), routines: book);
      final run = agent.runRoutine(book.find('순찰')!);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(agent.progress!.rounds, 0);
      expect(agent.progress!.round, 2, reason: 'one round, a 1 s wait, then the second');
      agent.stop();
      final r = await run.timeout(const Duration(seconds: 2));
      expect(r.error, 'Interrupted by stop.');
      expect(agent.progress, isNull);
      expect(agent.busy, isFalse);
    });

    test('"until stopped" with no pause still waits a moment between rounds (no runaway loop)', () async {
      await book.save(Routine(id: 'q', name: 'check', steps: [call('get_status')], repeat: 0));
      final agent = RobotAgent(drive: drive, nav: nav, backend: NoPlanner(), routines: book);
      final run = agent.runRoutine(book.find('check')!);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(agent.progress!.round, lessThanOrEqualTo(3), reason: 'about one round a second, not thousands');
      agent.stop();
      final r = await run.timeout(const Duration(seconds: 2));
      expect(r.error, 'Interrupted by stop.');
      expect(r.results.length, lessThanOrEqualTo(20));
    });

    test('running a routine checks every step and stops at the first refused one', () async {
      await book.save(Routine(id: 'x', name: '이상한', steps: [call('stop'), call('fly', {'height': 3}), call('stop')]));
      final agent = RobotAgent(drive: drive, nav: nav, backend: NoPlanner(), routines: book);
      final run = await agent.runRoutine(book.find('이상한')!, source: 'schedule');
      expect(run.ok, isFalse);
      expect(run.results.single.message, contains('stopped at fly'));
      expect(agent.log.entries.where((e) => e.text.startsWith('stop()')), hasLength(1), reason: 'the third step did not run');
      expect(agent.log.entries.first.source, 'schedule');
    });
  });

  testWidgets('build a routine on screen, then run it', (tester) async {
    final robot = FakeConnection();
    final ros = RosClient(robot);
    final drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    final nav = NavigationController(ros);
    final book = RoutineBook('r');
    final agent = RobotAgent(drive: drive, nav: nav, backend: NoPlanner(), routines: book);
    await tester.pumpWidget(MaterialApp(home: RoutinesPage(book: book, agent: agent)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('routine-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('routine-name')), '회전');
    await tester.tap(find.byKey(const Key('routine-add-step')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('routine-skill')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Turn in place').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('routine-param-angle_deg')), '999');
    await tester.tap(find.byKey(const Key('routine-step-add')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Turn in place · 360'), findsOneWidget, reason: 'clamped by the validator, shown in plain words');
    await tester.tap(find.byKey(const Key('routine-save')));
    await tester.pumpAndSettle();

    expect(book.find('회전')!.steps.single.call!.name, 'rotate');
    expect(find.byKey(const Key('routine-회전')), findsOneWidget);
    drive.dispose();
    nav.dispose();
  });
}
