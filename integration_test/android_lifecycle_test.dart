// Run twice via tool/run_android_lifecycle.mjs on the isolated, hidden emulator-5580.
// No app main()/CloudSession: approval links are observed without account/network requests.
import 'dart:io' show pid;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/app_links.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_session.dart';
import '../test/support/fake_ros_connection.dart';

const _run = String.fromEnvironment('QA_RESTART_RUN');
Future<void> _screen(WidgetTester tester, String name) async {
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
  debugPrint('QA_SCREEN $name');
  await Future<void>.delayed(const Duration(seconds: 2));
}
Widget _frame(Widget page) => MaterialApp(theme: buildTheme(Brightness.light), home: page);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('robot and person memory survive a real Android process restart', (tester) async {
    expect(RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(_run), isTrue,
        reason: 'Use the lifecycle runner to assign this run its own QA scopes.');
    final prefs = await SharedPreferences.getInstance();
    final marker = 'qa-restart:$_run';
    final stage = prefs.getString(marker);
    final connection = FakeConnection();
    RobotSession robot(String ns) => RobotSession(connection: connection, ip: stage == null ? 'qa-first-address' : 'qa-new-address',
        port: '9090', namespace: ns, storeKey: 'qa-restart:$_run');
    final first = robot('/robot1'), second = robot('/robot2'), person = Memory('qa-person:$_run');
    addTearDown(() { first.dispose(); second.dispose(); person.dispose(); connection.close(); });
    if (stage == null) {
      await first.memory.setProfile(RobotPersona.nameKey, 'さくら');
      await first.memory.add('note', 'Avoid the loading bay.', pinned: true);
      await second.memory.setProfile(RobotPersona.nameKey, 'Delivery Two');
      await person.setProfile(RobotPersona.callPersonKey, 'Minsu');
      expect([first.memory.lastError, second.memory.lastError, person.lastError], everyElement(isNull));
      expect(await prefs.setString(marker, 'seed:$pid'), isTrue);
      await tester.pumpWidget(_frame(RobotMemoryPage(session: first, person: person)));
      await _screen(tester, 'lifecycle-seeded');
      debugPrint('QA_RESTART_SEEDED $_run pid=$pid');
      // Intentionally retain just these QA scopes for the second process. No mock preferences.
    } else {
      expect(stage, startsWith('seed:'));
      expect(int.parse(stage.substring(5)), isNot(pid), reason: 'A new Memory object alone is not a process restart.');
      await first.memory.load(); await second.memory.load(); await person.load();
      expect(first.label, 'さくら'); expect(second.label, 'Delivery Two');
      expect(first.memory.ofKind('note').single.text, 'Avoid the loading bay.');
      expect(second.memory.ofKind('note'), isEmpty);
      expect(person.profile(RobotPersona.callPersonKey), 'Minsu');
      await tester.pumpWidget(_frame(RobotMemoryPage(session: first, person: person)));
      await tester.pumpAndSettle();
      expect(find.text('さくら'), findsOneWidget);
      expect(find.text('Minsu'), findsOneWidget);
      await tester.ensureVisible(find.text('Avoid the loading bay.'));
      await _screen(tester, 'lifecycle-restored');
      await first.memory.clear(); await second.memory.clear(); await person.clear();
      expect(await prefs.remove(marker), isTrue);
      debugPrint('QA_RESTART_VERIFIED $_run pid=$pid');
    }
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));

  testWidgets('Android approval intents reach Dart while foreign hosts, schemes, paths and actions do not', (tester) async {
    final received = ValueNotifier<List<String>>([]);
    final subscription = AppLinks.codes.listen((code) => received.value = [...received.value, code]);
    addTearDown(() async { await subscription.cancel(); received.dispose(); });
    await AppLinks.start();
    expect(AppLinks.takePending(), isNull, reason: 'The test launcher starts without an approval URI.');
    await tester.pumpWidget(_frame(Scaffold(appBar: AppBar(title: const Text('Android approval link check')),
      body: ValueListenableBuilder<List<String>>(valueListenable: received,
        builder: (_, codes, _) => Padding(padding: const EdgeInsets.all(24),
          child: Text(codes.isEmpty ? 'Waiting for approval link' : codes.join('\n')))))));
    Future<void> waitFor(String code) async {
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!received.value.contains(code) && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(received.value, contains(code), reason: 'The host must inject the native Android intent.');
    }
    debugPrint('QA_LINK_READY');
    await waitFor('ABCD-EFGH');
    debugPrint('QA_LINK_REJECTED_READY');
    // The host sends rejected intents followed by a valid sentinel, preserving delivery order.
    await waitFor('WXYZ-2345');
    expect(received.value, ['ABCD-EFGH', 'WXYZ-2345']);
    await _screen(tester, 'lifecycle-links');
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
