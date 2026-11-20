import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'log_page.dart';
import 'monitor_page.dart';
import 'robot_log.dart';
import 'ros_connection.dart';
import 'tool_tabs.dart';

/// "Robot status": the sensors (with graphs) and the robot's log on one screen, two tabs at the bottom.
/// Looking into a problem means both, so they are not two tiles. The log is marked read only once its
/// tab is looked at.
class RobotStatusPage extends StatefulWidget {
  const RobotStatusPage({super.key, required this.ip, required this.port, required this.log,
    this.connectionFactory = RosConnection.new, this.online = true, this.startOnLog = false});

  final String ip;
  final String port;
  final RobotLog log;
  final RosConnection Function(String, String) connectionFactory;

  /// Without a connection only the log (kept from before) can be read.
  final bool online;

  /// Opens on the log (new problems are waiting).
  final bool startOnLog;

  @override
  State<RobotStatusPage> createState() => _RobotStatusPageState();
}

class _RobotStatusPageState extends State<RobotStatusPage> {
  @override
  void initState() {
    super.initState();
    widget.log.addListener(_onLog);
  }

  @override
  void dispose() {
    widget.log.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (mounted) setState(() {}); // the badge on the Log tab
  }

  @override
  Widget build(BuildContext context) => ToolTabs(
    title: context.strings.robotStatus,
    barKey: const Key('status-tabs'),
    // Offline only the log (kept from before) can be read: no Sensors tab then.
    initial: widget.startOnLog && widget.online ? 1 : 0,
    tabs: [
      if (widget.online) ToolTab(key: const Key('status-tab-sensors'), label: context.strings.sensors, icon: Icons.insights_outlined,
        build: (_) => SensorPage(ip: widget.ip, port: widget.port, connectionFactory: widget.connectionFactory)),
      ToolTab(key: const Key('status-tab-log'), label: context.strings.log, badge: widget.log.unseenProblems,
        icon: Icons.receipt_long_outlined, build: (_) => RobotLogPage(log: widget.log)),
    ],
  );
}
