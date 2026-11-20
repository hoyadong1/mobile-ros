// Run with tool/run_android_review.mjs --offline on emulator-5580.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/app_language.dart';
import 'package:ros_tester/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android changes UI language through the menu and keeps the connection draft', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString('app_language');
    addTearDown(() async {
      if (previous == null) {
        await prefs.remove('app_language');
      } else {
        await prefs.setString('app_language', previous);
      }
    });
    await prefs.remove('app_language');
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('Connect to your robot'), findsOneWidget);
    final host = find.byKey(const Key('robot-host'));
    await tester.enterText(host, '192.168.1.42');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    for (final (code, title) in [
      ('ko', '로봇 연결'), ('ja', 'ロボットに接続'), ('zh', '连接机器人'),
      ('es', 'Conecta tu robot'), ('en', 'Connect to your robot'),
    ]) {
      await tester.tap(find.byKey(const Key('app-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-language')));
      await tester.pumpAndSettle();
      final choice = find.byKey(Key('app-language-$code'));
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(tester.widget<TextFormField>(host).controller?.text, '192.168.1.42');
      await prefs.reload();
      expect(prefs.getString('app_language'), code);
      expect(tester.takeException(), isNull);
      debugPrint('QA_SCREEN language-$code');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    await loadAppLanguage();
    expect(appLocale.value, const Locale('en'));
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 2)));
}
