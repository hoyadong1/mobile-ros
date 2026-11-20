import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'fleet_agent_page.dart';
import 'fleet_overview_page.dart';
import 'robot_session.dart';
import 'tool_tabs.dart';

/// Every robot on one map, and instructions for several at once, on one screen (two tabs).
class FleetPage extends StatelessWidget {
  const FleetPage({super.key, required this.sessions});
  final List<RobotSession> sessions;

  @override
  Widget build(BuildContext context) => ToolTabs(
    title: context.strings.fleet,
    barKey: const Key('fleet-tabs'),
    tabs: [
      ToolTab(key: const Key('fleet-tab-map'), label: context.strings.robots, icon: Icons.dashboard_outlined,
        build: (_) => FleetOverviewPage(sessions: sessions)),
      ToolTab(key: const Key('fleet-tab-ask'), label: context.strings.ask, icon: Icons.groups_outlined,
        build: (_) => FleetAgentPage(sessions: sessions)),
    ],
  );
}
