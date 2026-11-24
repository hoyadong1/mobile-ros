import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/agent/audit_log.dart';
import 'package:ros_tester/agent_page.dart';
import 'package:ros_tester/app_language.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/connect_page.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/explorer_page.dart';
import 'package:ros_tester/incident_recorder.dart';
import 'package:ros_tester/incidents_page.dart';
import 'package:ros_tester/fleet_overview_page.dart';
import 'package:ros_tester/l10n/generated/app_localizations.dart';
import 'package:ros_tester/log_page.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/monitor_page.dart';
import 'package:ros_tester/params_page.dart';
import 'package:ros_tester/publish_page.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/topic_health_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test/support/fake_cloud_session.dart';
import '../test/support/fake_ros_connection.dart';

const _capture = Key('localized-capture');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const code = String.fromEnvironment('QA_LOCALE', defaultValue: 'ko');
  final locale = Locale(code);
  final messages = lookupAppLocalizations(locale);
  const font = 'ReviewText';
  setUpAll(() async {
    final sdk = Platform.environment['FLUTTER_ROOT'];
    if (sdk == null) throw StateError('Set FLUTTER_ROOT to the installed Flutter SDK.');
    final materialFonts = '$sdk/bin/cache/artifacts/material_fonts';
    // Use real glyph widths. Ahem's equally wide letters give misleading results at 200%.
    final fontFile = Platform.environment['QA_LOCALE_FONT'] ?? '$materialFonts/roboto-regular.ttf';
    for (final (family, file) in [(font, fontFile), ('MaterialIcons', '$materialFonts/materialicons-regular.otf')]) {
      final loader = FontLoader(family)..addFont(File(file).readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });

  for (final (size, scale) in [(const Size(320, 640), 2.0), (const Size(390, 844), 1.0), (const Size(1280, 800), 1.0)]) {
    for (final page in ['connect', 'workspace', 'drive', 'map', 'fleet', 'assistant', 'memory',
      'sensors', 'log', 'tune', 'explorer', 'publish', 'account', 'incident', 'health']) {
      testWidgets('$code $page at $size and ${scale}x', (tester) async {
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        final viewport = page == 'drive' && size.width < size.height ? Size(size.height, size.width) : size;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = viewport;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final link = FakeConnection()..serviceResponses['/rosapi/topics'] = {
          'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom', '/map'],
          'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
            'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/OccupancyGrid'],
        };
        final first = RobotSession(connection: link, ip: 'qa-robot', port: '9090', namespace: '/robot1');
        final second = RobotSession(connection: link, ip: 'qa-robot', port: '9090', namespace: '/robot2');
        addTearDown(() {
          first.dispose();
          second.dispose();
          if (!link.isClosed) link.close();
        });
        await ProfileStore.saveAt(first.storeAddress, RobotProfile.defaults(
          DriveType.differential, commandTopic: '/robot1/cmd_vel'));

        final (screen, text) = switch (page) {
          'connect' => (const ConnectPage(), messages.connectTitle),
          'workspace' => (MainPage(ip: first.ip, port: first.port, connection: link,
            connectionFactory: (_, _) => link), messages.aiRoutines),
          'drive' => (ControlScreen(ip: first.ip, port: first.port, channel: link,
            namespace: first.namespace, storeAddress: first.storeAddress,
            imageConnectionFactory: (_, _) => link), messages.stop),
          'map' => (MapVisualizationPage(ip: first.ip, port: first.port, namespace: first.namespace,
            connectionFactory: (_, _) => link), messages.mapNavigation),
          'assistant' => (AgentPage(session: first, log: AuditLog()), messages.tellRobot),
          'memory' => (RobotMemoryPage(session: first), messages.namePersonality),
          'sensors' => (SensorPage(ip: first.ip, port: first.port, connectionFactory: (_, _) => link), messages.sensors),
          'log' => (RobotLogPage(log: first.robotLog), messages.log),
          'tune' => (TuneRobotPage(session: first), messages.tuneRobot),
          'explorer' => (ExplorerPage(ip: first.ip, port: first.port, connectionFactory: (_, _) => link), messages.rosExplorer),
          'publish' => (PublishPage(ip: first.ip, port: first.port, connectionFactory: (_, _) => link), messages.publishMessage),
          'account' => (CloudRobotsPage(session: FakeCloudSession()), messages.signIn),
          'incident' => (IncidentPage(incident: (IncidentRecorder()..pose(0, 0)..pose(1, 0.5)
              ..record(IncidentKind.log, 'controller_server: no valid control', level: 'error'))
              .snapshot('robot1', messages.reasonNavFailed)), messages.reasonNavFailed),
          'health' => (TopicHealthPage(connection: link, topicTypes: const {
              '/scan': 'sensor_msgs/msg/LaserScan', '/robot1/odom': 'nav_msgs/msg/Odometry'}), messages.topicHealth),
          _ => (FleetOverviewPage(sessions: [first, second]), messages.fleetOverview),
        };
        final base = buildTheme(Brightness.light);
        final theme = base.copyWith(textTheme: base.textTheme.apply(fontFamily: font),
          filledButtonTheme: FilledButtonThemeData(style: base.filledButtonTheme.style?.copyWith(
            textStyle: WidgetStateProperty.resolveWith((states) =>
              base.filledButtonTheme.style?.textStyle?.resolve(states)?.copyWith(fontFamily: font)))),
          appBarTheme: base.appBarTheme.copyWith(titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontFamily: font)),
          listTileTheme: base.listTileTheme.copyWith(
            titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(fontFamily: font),
            subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: font)));
        Future<void> capture(String surface) async {
          if (Platform.environment['QA_CAPTURE'] != '1') return; // pictures only on request
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(_capture));
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
              final folder = Directory('build/localized-ui/$code');
              await folder.create(recursive: true);
              final name = '${viewport.width.toInt()}x${viewport.height.toInt()}-${scale}x-$surface.png';
              await File('${folder.path}/$name').writeAsBytes(bytes!.buffer.asUint8List());
            } finally {
              image.dispose();
            }
          });
        }
        await tester.pumpWidget(MaterialApp(theme: theme, locale: locale,
          localizationsDelegates: appLocalizationDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: _capture, child: child!)),
          home: screen));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        final built = tester.takeException();
        if (built != null) await capture(page);
        expect(built, isNull);
        Future<void> checkLabel(String value) async {
          final label = find.text(value).first;
          expect(label, findsOneWidget);
          await tester.ensureVisible(label);
          await tester.pump(const Duration(milliseconds: 400));
          final render = tester.renderObject(label);
          if (render is RenderParagraph) expect(render.didExceedMaxLines, isFalse, reason: value);
          expect(tester.takeException(), isNull);
        }

        if (page == 'workspace') await capture('workspace-top');
        await capture(page); // before the checks, so a failing page still leaves its picture
        // A segmented button's names must stay on one line: "rosb / ridg / e" and "Make / map" were found on a phone.
        for (final segmented in find.byWidgetPredicate((w) => w is SegmentedButton).evaluate()) {
          for (final text in find.descendant(of: find.byWidget(segmented.widget), matching: find.byType(RichText)).evaluate()) {
            final paragraph = text.renderObject! as RenderParagraph;
            final length = paragraph.text.toPlainText().length;
            final lines = {for (final box in paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: length)))
              box.top.round()}.length;
            expect(lines, lessThanOrEqualTo(1), reason: 'segment "${paragraph.text.toPlainText()}" wraps on $page');
          }
        }
        await checkLabel(text);
        if (page == 'connect') {
          final connect = find.byKey(const Key('connect-button'));
          await tester.ensureVisible(connect);
          await tester.tap(connect);
          await tester.pumpAndSettle();
          await checkLabel(messages.enterWebsocket);
          await capture('connect-error');
          await tester.tap(find.byKey(const Key('app-menu')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('app-language')));
          await tester.pumpAndSettle();
          expect(find.byKey(Key('app-language-$code')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture('language');
        }
        if (page == 'drive') {
          final stop = find.byKey(const Key('estop'));
          expect(tester.getRect(stop).right, lessThanOrEqualTo(viewport.width));
          expect(tester.getRect(stop).width, greaterThanOrEqualTo(48));
          expect(tester.getRect(stop).height, greaterThanOrEqualTo(48));
        }
        if (page == 'map') {
          link.events.add({'op': 'publish', 'topic': '/map', 'msg': {
            'header': {'frame_id': 'map'},
            'info': {'width': 10, 'height': 10, 'resolution': 1.0, 'origin': {
              'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
            'data': List.filled(100, 0),
          }});
          await tester.pumpAndSettle();
          final state = tester.state<MapPageState>(find.byType(MapVisualizationPage));
          final painter = find.byWidgetPredicate((widget) => widget is CustomPaint && widget.painter is MapPainter);
          final box = tester.renderObject<RenderBox>(painter);
          // The left side of the map stays clear of the action controls.
          await tester.tapAt(box.localToGlobal(state.toCanvas(3.5, 4.5)));
          await tester.pump(const Duration(milliseconds: 500));
          await checkLabel(messages.go);
          expect(find.byKey(const Key('goal-go')).hitTestable(), findsOneWidget);
          await capture('map-goal');
        }
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
