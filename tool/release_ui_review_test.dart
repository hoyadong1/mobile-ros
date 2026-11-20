// Off-screen rendering only; no emulator or desktop window is opened.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/connect_page.dart';
import 'package:ros_tester/main_page.dart';
import '../test/support/fake_ros_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) throw StateError('Set FLUTTER_ROOT to capture readable UI review images.');
    for (final font in [('Roboto', 'roboto-regular.ttf'), ('MaterialIcons', 'materialicons-regular.otf')]) {
      final loader = FontLoader(font.$1)..addFont(
        File('$root/bin/cache/artifacts/material_fonts/${font.$2}').readAsBytes()
          .then((data) => ByteData.sublistView(data)));
      await loader.load();
    }
  });
  for (final size in [const Size(390, 844), const Size(1280, 800), const Size(800, 1280)]) {
    for (final scale in [1.0, 2.0]) {
    for (final brightness in Brightness.values) {
      testWidgets('release surfaces $size at ${scale}x text ${brightness.name}', (tester) async {
        // This file is a Flutter test run explicitly from tool/.
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        const capture = Key('release-capture');
        final base = buildTheme(brightness);
        // The test engine substitutes Ahem for an unspecified font. Specify the
        // normal Android font in standalone theme styles for readable evidence.
        final theme = base.copyWith(
          textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
          appBarTheme: base.appBarTheme.copyWith(
            titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto')),
          listTileTheme: base.listTileTheme.copyWith(
            titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
            subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Roboto')),
          filledButtonTheme: FilledButtonThemeData(style: base.filledButtonTheme.style?.copyWith(
            textStyle: WidgetStateProperty.resolveWith((states) =>
              base.filledButtonTheme.style?.textStyle?.resolve(states)?.copyWith(fontFamily: 'Roboto')))),
        );
        Widget frame(Widget page) => MaterialApp(theme: theme,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: capture, child: child)), home: page);
        final prefix = '${size.width.toInt()}x${size.height.toInt()}-${scale.toInt()}x-${brightness.name}';
        Future<void> save(String page) async {
          expect(tester.takeException(), isNull);
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            final directory = Directory('build/release-ui');
            await directory.create(recursive: true);
            await File('${directory.path}/$prefix-$page.png').writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(frame(const ConnectPage()));
        await tester.pumpAndSettle();
        await save('connect');
        final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
          'topics': ['/cmd_vel', '/odom', '/map'],
          'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/OccupancyGrid']};
        await tester.pumpWidget(frame(MainPage(ip: 'simulated-robot', port: '9090', connection: robot)));
        await tester.pumpAndSettle();
        robot.events.add({'op': 'publish', 'topic': '/map', 'msg': {
          'header': {'frame_id': 'map'},
          'info': {'width': 20, 'height': 20, 'resolution': 0.25,
            'origin': {'position': {'x': -2.5, 'y': -2.5, 'z': 0},
              'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1.0}}},
          'data': [for (var i = 0; i < 400; i++) i < 20 || i >= 380 || i % 20 == 0 || i % 20 == 19 ? 100 : 0],
        }});
        robot.events.add({'op': 'publish', 'topic': '/odom', 'msg': {
          'header': {'frame_id': 'map'}, 'child_frame_id': 'base_footprint',
          'pose': {'pose': {'position': {'x': 0.0, 'y': 0.0, 'z': 0},
            'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1.0}}},
        }});
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('mini-map')), findsOneWidget);
        expect(find.byKey(const Key('tool-control')), findsOneWidget);
        expect(find.byKey(const Key('stop-all')), findsOneWidget);
        await save('home');
        robot.close();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('reconnect')), findsOneWidget);
        await save('disconnected');
        await tester.pumpWidget(const SizedBox());
      });
    }
    }
  }
}
