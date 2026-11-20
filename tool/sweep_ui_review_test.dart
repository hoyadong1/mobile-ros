import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/audit_log.dart';
import 'package:ros_tester/assistant_page.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import 'package:ros_tester/fleet_agent_page.dart';
import 'package:ros_tester/fleet_overview_page.dart';
import 'package:ros_tester/fleet_page.dart';
import 'package:ros_tester/log_page.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/message_definitions_page.dart';
import 'package:ros_tester/params_page.dart';
import 'package:ros_tester/remote_setup_page.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/routines_page.dart';
import 'package:ros_tester/status_page.dart';
import 'package:ros_tester/support_page.dart';

import '../test/support/fake_ros_connection.dart';

class _Quiet extends AgentBackend {
  @override
  String get name => 'none';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => const AgentPlan();
}

// Pictures (real font) of the screens the sweep checks:  FLUTTER_ROOT=<sdk> flutter test tool/sweep_ui_review_test.dart
/// Every screen not covered by responsive_review_test: no overflow or error on a small phone with large
/// text, nor on a tablet in landscape.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT']!;
    for (final font in [('Roboto', 'roboto-regular.ttf'), ('MaterialIcons', 'materialicons-regular.otf')]) {
      final loader = FontLoader(font.$1)..addFont(File('$root/bin/cache/artifacts/material_fonts/${font.$2}')
          .readAsBytes().then((d) => ByteData.sublistView(d)));
      await loader.load();
    }
  });
  const pages = ['assistant', 'routines', 'status', 'log', 'tune', 'fleet', 'fleet-overview', 'fleet-assistant',
    'memory', 'support', 'my-robots', 'remote-setup', 'definitions'];
  for (final (size, scale) in [(const Size(320, 640), 2.0), (const Size(360, 740), 1.3), (const Size(1280, 800), 1.0)]) {
    for (final page in pages) {
      testWidgets('$page fits $size at ${scale}x', (tester) async {
        // ignore: invalid_use_of_visible_for_testing_member
        SharedPreferences.setMockInitialValues({});
        // ignore: invalid_use_of_visible_for_testing_member
        Memory.user.unload();
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final link = FakeConnection()..serviceResponses['/rosapi/topics'] = {
          'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot1/battery_state', '/robot2/cmd_vel', '/robot2/odom', '/map'],
          'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/BatteryState',
            'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/OccupancyGrid'],
        };
        final s1 = RobotSession(connection: link, ip: 'robot', port: '9090', namespace: '/robot1');
        final s2 = RobotSession(connection: link, ip: 'robot', port: '9090', namespace: '/robot2');
        final log = AuditLog();
        final routineAgent = RobotAgent.forSession(s1, _Quiet(), log: log);
        final Widget screen = switch (page) {
          'assistant' => AssistantPage(session: s1, log: log, routineAgent: routineAgent),
          'routines' => RoutinesPage(book: s1.routines, agent: routineAgent),
          'status' => RobotStatusPage(ip: 'robot', port: '9090', log: s1.robotLog, connectionFactory: (a, b) => link),
          'log' => RobotLogPage(log: s1.robotLog),
          'tune' => TuneRobotPage(session: s1),
          'fleet' => FleetPage(sessions: [s1, s2]),
          'fleet-overview' => FleetOverviewPage(sessions: [s1, s2]),
          'fleet-assistant' => FleetAgentPage(sessions: [s1, s2]),
          'memory' => RobotMemoryPage(session: s1, others: [s2]),
          'support' => const SupportPage(),
          'my-robots' => const CloudRobotsPage(),
          'remote-setup' => const RemoteSetupPage(host: 'robot', name: 'robot1'),
          _ => const MessageDefinitionsPage(),
        };
        final base = buildTheme(Brightness.light);
        final theme = base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
            appBarTheme: base.appBarTheme.copyWith(titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto')),
            listTileTheme: base.listTileTheme.copyWith(
              titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
              subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Roboto')));
        const capture = Key('capture');
        await tester.pumpWidget(MaterialApp(theme: theme, builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: capture, child: child!)), home: screen));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        final early = tester.takeException(); // the picture is taken either way
        await tester.pump(const Duration(seconds: 2));
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/sweep-ui').create(recursive: true);
          await File('build/sweep-ui/${size.width.toInt()}x${size.height.toInt()}-${scale}x-$page.png')
              .writeAsBytes(bytes!.buffer.asUint8List());
        });
        expect(early, isNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 6)); // timers a screen started run out
        routineAgent.dispose();
        s1.dispose();
        s2.dispose();
        if (!link.isClosed) link.close();
      });
    }
  }
}
