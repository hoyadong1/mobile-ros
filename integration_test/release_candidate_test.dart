// Run only on the isolated emulator-5580, through tool/run_android_review.mjs --offline.
// Native Android plugins/storage and real Flutter surfaces; all ROS and AI data are fake.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/main.dart' as app;
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/connect_page.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import '../test/support/fake_ros_connection.dart';

const _host = 'release-qa', _port = '9090';
FakeConnection _robots() => FakeConnection()..serviceResponses['/rosapi/topics'] = {
  'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom'],
  'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
    'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
};
RobotSession _session(FakeConnection c, {String ip = _host, String namespace = '/robot1'}) =>
    RobotSession(connection: c, ip: ip, port: _port, namespace: namespace, storeKey: '$_host:$_port');
Widget _frame(Widget page) => MaterialApp(theme: buildTheme(Brightness.light), home: page);
Future<void> _screen(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  debugPrint('QA_SCREEN $name');
  await Future<void>.delayed(const Duration(seconds: 2));
}
class _DelayedPlanner extends AgentBackend {
  final answer = Completer<AgentPlan>();
  final entered = Completer<void>();
  @override
  String get name => 'QA delayed planner';
  @override
  Future<AgentPlan> plan(AgentRequest request) { entered.complete(); return answer.future; }
}
class _MustNotGenerate extends LocalModel {
  @override
  Future<String> generate({required String system, required String user, required String grammar, int maxTokens = 160}) =>
      throw StateError('An unsupported request reached the small model.');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android starts the real entry point with the expected account flag', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    expect(find.byType(ConnectPage), findsOneWidget);
    expect(find.byKey(const Key('my-robots')), cloudAccountsEnabled ? findsOneWidget : findsNothing);
    await _screen(tester, 'release-connect');
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('native memory survives a new session at a new address and stays robot-scoped', (tester) async {
    final c = _robots(), person = Memory('release-qa-person');
    final first = _session(c), second = _session(c, namespace: '/robot2');
    final restored = _session(c, ip: 'release-qa-new-address');
    addTearDown(() async {
      await first.memory.clear(); await second.memory.clear(); await person.clear();
      first.dispose(); second.dispose(); restored.dispose(); c.close(); person.dispose();
    });
    await first.memory.clear(); await second.memory.clear(); await person.clear();
    await tester.pumpWidget(_frame(RobotMemoryPage(session: first, person: person)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('memory-name')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memory-edit-field')), 'さくら');
    await tester.tap(find.byKey(const Key('memory-edit-save')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('memory-add-note')));
    await tester.tap(find.byKey(const Key('memory-add-note')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('memory-note-field')), 'Avoid the loading bay.');
    await tester.tap(find.byKey(const Key('memory-note-save')));
    await _screen(tester, 'release-memory');
    expect(first.memory.lastError, isNull);
    // Discard SharedPreferences' Dart cache before reading a fresh Memory instance. No mock store.
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getString(PrefsMemoryStore.keyOf(first.memory.scope)), contains('さくら'));
    await restored.memory.load(); await second.memory.load();
    expect(restored.label, 'さくら');
    expect(restored.memory.ofKind('note').single.text, 'Avoid the loading bay.');
    expect(second.memory.profile(RobotPersona.nameKey), isNull);
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Android workspace switches robots and requests STOP on both command topics', (tester) async {
    final c = _robots();
    for (final name in ['robot1', 'robot2']) {
      await ProfileStore.saveAt('$_host:$_port/$name',
          RobotProfile.defaults(DriveType.differential, commandTopic: '/$name/cmd_vel'));
    }
    await tester.pumpWidget(_frame(MainPage(ip: _host, port: _port, connection: c,
        connectionFactory: (_, _) => c)));
    await tester.pumpAndSettle();
    for (final name in ['robot1', 'robot2']) {
      final chip = find.byKey(Key('robot-$name'));
      await tester.ensureVisible(chip); await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(chip).selected, isTrue);
      await tester.ensureVisible(find.byKey(const Key('tool-control')));
      await tester.tap(find.byKey(const Key('tool-control')));
      // Drive intentionally keeps rendering (joysticks/live feeds), so waiting for zero scheduled
      // frames would never finish on a real Android engine.
      await tester.pump(const Duration(seconds: 1));
      await tester.pageBack(); await tester.pumpAndSettle();
    }
    c.sent.clear();
    await tester.ensureVisible(find.byKey(const Key('stop-all')));
    await tester.tap(find.byKey(const Key('stop-all')));
    await tester.pumpAndSettle();
    expect(find.text('Stop requested for all robots.'), findsWidgets);
    for (final name in ['robot1', 'robot2']) {
      expect(c.sent, contains(predicate<Map<String, dynamic>>((m) => m['op'] == 'publish' &&
          m['topic'] == '/$name/cmd_vel' && m['msg']['linear']['x'] == 0 && m['msg']['angular']['z'] == 0)));
    }
    await _screen(tester, 'release-fleet-stop');
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Android refuses unsupported offline commands and discards plans arriving after STOP', (tester) async {
    final s = _session(_robots());
    final delayed = _DelayedPlanner();
    final agent = RobotAgent.forSession(s, delayed);
    addTearDown(() { agent.dispose(); s.dispose(); s.connection.close(); });
    await s.prepare();
    final router = RouterBackend(local: LocalBackend(_MustNotGenerate()), cloudAllowed: () => false);
    final refusal = await router.plan(AgentRequest(instruction: '向前走50厘米直到看到人',
        manifest: agent.manifest(), status: const {}));
    expect(refusal.calls, isEmpty); expect(refusal.reply, contains('没有执行'));
    final running = agent.handle('go forward 50 cm');
    await delayed.entered.future;
    final stopped = await agent.handle('止まって！');
    expect(stopped.ok, isTrue);
    delayed.answer.complete(const AgentPlan(calls: [SkillCall('move', {'direction': 'forward', 'distance_m': 0.5})]));
    expect((await running).error, 'Interrupted by stop.');
    final sent = (s.connection as FakeConnection).sent;
    expect(sent.where((m) => m['op'] == 'publish' && m['topic'] == '/robot1/cmd_vel' &&
        m['msg']['linear']['x'] != 0), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
