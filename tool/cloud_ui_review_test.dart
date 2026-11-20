// Off-screen UI evidence with synthetic accounts. Never captures real email, passwords or tokens.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import '../test/support/fake_cloud_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) throw StateError('Set FLUTTER_ROOT for readable UI evidence.');
    for (final font in [('Roboto', 'roboto-regular.ttf'), ('MaterialIcons', 'materialicons-regular.otf')]) {
      await (FontLoader(font.$1)..addFont(File('$root/bin/cache/artifacts/material_fonts/${font.$2}')
        .readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('account surfaces $size at ${scale}x text', (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final theme = buildTheme(Brightness.light);
        const capture = Key('cloud-capture');
        Widget frame(FakeCloudSession session) => MaterialApp(
          theme: theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'Roboto'),
            appBarTheme: theme.appBarTheme.copyWith(titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto')),
            filledButtonTheme: FilledButtonThemeData(style: theme.filledButtonTheme.style?.copyWith(
              textStyle: WidgetStateProperty.resolveWith((states) => theme.filledButtonTheme.style?.textStyle?.resolve(states)?.copyWith(fontFamily: 'Roboto'))))),
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: capture, child: child)), home: CloudRobotsPage(session: session));
        Future<void> save(String page) async {
          expect(tester.takeException(), isNull);
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory('build/cloud-ui').create(recursive: true);
            await File('build/cloud-ui/${size.width.toInt()}x${size.height.toInt()}-${scale.toInt()}x-$page.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        final signedOut = FakeCloudSession();
        await tester.pumpWidget(frame(signedOut));
        await tester.pumpAndSettle();
        await save('signin');
        await tester.ensureVisible(find.byKey(const Key('cloud-switch-mode')));
        await tester.tap(find.byKey(const Key('cloud-switch-mode')));
        await tester.pumpAndSettle();
        await save('signup');
        await tester.enterText(find.byKey(const Key('cloud-email')), 'owner@example.com');
        await tester.enterText(find.byKey(const Key('cloud-password')), 'fake-preview-password');
        await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'fake-preview-password');
        await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
        await tester.tap(find.byKey(const Key('cloud-signin')));
        await tester.pumpAndSettle();
        await save('verify-email');
        await tester.pumpWidget(const SizedBox());
        signedOut.dispose();
        final signedIn = FakeCloudSession(signedIn: true)..claimed = true;
        await tester.pumpWidget(frame(signedIn));
        await tester.pumpAndSettle();
        await save('robots');
        await tester.ensureVisible(find.byKey(const Key('cloud-add')));
        await tester.tap(find.byKey(const Key('cloud-add')));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('cloud-claim-code')));
        await save('register');
        await tester.pumpWidget(const SizedBox());
        signedIn.dispose();
      });
    }
  }
}
