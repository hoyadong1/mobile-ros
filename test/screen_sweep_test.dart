import 'package:flutter_test/flutter_test.dart';
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

import 'support/fake_ros_connection.dart';

class _Quiet extends AgentBackend {
  @override
  String get name => 'none';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => const AgentPlan();
}

/// Every screen not covered by responsive_review_test: no overflow or error on a small phone with large
/// text, nor on a tablet in landscape.
void main() {
  const pages = ['assistant', 'routines', 'status', 'log', 'tune', 'fleet', 'fleet-overview', 'fleet-assistant',
    'memory', 'support', 'my-robots', 'remote-setup', 'definitions'];
  // The test font (Ahem: every letter a square) is much wider than a phone's, so the smallest phone at 2x text
  // is checked with the real font in tool/sweep_ui_review_test.dart instead.
  for (final (size, scale) in [(const Size(360, 740), 1.3), (const Size(1280, 800), 1.0)]) {
    for (final page in pages) {
      testWidgets('$page fits $size at ${scale}x', (tester) async {
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
        await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!), home: screen));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        await tester.pump(const Duration(seconds: 2));
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
