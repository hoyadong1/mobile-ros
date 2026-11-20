import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/background_service.dart';
import 'package:ros_tester/main.dart' as app;
import 'package:ros_tester/robot_widget.dart';
import 'package:ros_tester/support_page.dart';

void main() {
  testWidgets('app starts on the web and validates the connection form', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Exercise the real entry point, including platform services before runApp.
    await app.main();
    await tester.pumpAndSettle();
    expect(find.text('Mobile ROS'), findsOneWidget);
    if (kIsWeb) {
      expect(ForegroundPresence.supported, isFalse);
      expect(RobotWidget.supported, isFalse);
    }
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a host/IP or a valid ws:// or wss:// URL.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (kIsWeb) {
      await tester.pumpWidget(const MaterialApp(home: SupportPage()));
      await tester.pumpAndSettle();
      expect(find.text('Available in the app from Google Play.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  }, skip: !kIsWeb); // The native suite covers widgets; this exercises browser startup.
}
