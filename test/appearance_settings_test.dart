import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent_page.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('appearance: follows the phone by default; Dark is remembered and applied', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await loadThemeMode();
    expect(appThemeMode.value, ThemeMode.system);
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-dark')));
    await tester.pumpAndSettle();
    expect(appThemeMode.value, ThemeMode.dark);
    expect(Theme.of(tester.element(find.text('Connect to your robot'))).brightness, Brightness.dark);
    expect((await SharedPreferences.getInstance()).getString('theme_mode'), 'dark');
    await setThemeMode(ThemeMode.system);
  });

  testWidgets('assistant settings: choose where it runs; the status line says what is missing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    AgentSettings? saved;
    Future<void> open(BuildContext context) async {
      saved = await showDialog<AgentSettings>(context: context,
          builder: (_) => const AgentSettingsDialog(initial: AgentSettings()));
    }
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: FilledButton(onPressed: () => open(context), child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Online by default: the address and token fields, and what is still missing.
    expect(find.byKey(const Key('agent-proxy-url')), findsOneWidget);
    expect(find.text('Enter the address and token of the assistant on your PC.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('agent-proxy-url')), 'http://192.168.0.29:8787/v1/plan');
    await tester.enterText(find.byKey(const Key('agent-proxy-token')), 't1');
    await tester.pump();
    expect(find.textContaining('Ready.'), findsOneWidget);

    // On this phone: no online fields.
    await tester.ensureVisible(find.byKey(const Key('agent-mode-phone')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('agent-mode-phone')));
    await tester.pump();
    expect(find.byKey(const Key('agent-proxy-url')), findsNothing);
    await tester.tap(find.byKey(const Key('agent-settings-save')));
    await tester.pumpAndSettle();
    expect(saved?.onDeviceOnly, isTrue);
    expect(saved?.proxyUrl, 'http://192.168.0.29:8787/v1/plan', reason: 'the online setup is kept for later');
  });
}
