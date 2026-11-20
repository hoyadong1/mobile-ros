import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/app_language.dart';
import 'package:ros_tester/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('language choice updates the screen, keeps the form draft and is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({'app_language': 'unsupported'});
    addTearDown(() => appLocale.value = const Locale('en'));
    await loadAppLanguage();
    expect(appLocale.value, const Locale('en'));

    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect to your robot'), findsOneWidget);
    final host = find.byKey(const Key('robot-host'));
    await tester.enterText(host, '192.168.1.42');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    Future<void> choose(String language) async {
      await tester.tap(find.byKey(const Key('app-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('app-language')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('app-language-$language')));
      await tester.pumpAndSettle();
    }

    await choose('ko');
    expect(find.text('로봇 연결'), findsOneWidget);
    expect(tester.widget<TextFormField>(host).controller?.text, '192.168.1.42');
    expect((await SharedPreferences.getInstance()).getString('app_language'), 'ko');

    await tester.pumpWidget(const SizedBox());
    appLocale.value = const Locale('en');
    await loadAppLanguage();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('로봇 연결'), findsOneWidget);
    await choose('en');
    expect(find.text('Connect to your robot'), findsOneWidget);
  });
}
