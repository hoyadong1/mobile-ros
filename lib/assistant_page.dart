import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'agent/agent.dart';
import 'agent/audit_log.dart';
import 'agent_page.dart';
import 'robot_session.dart';
import 'routines_page.dart';
import 'tool_tabs.dart';

/// The assistant, with the saved routines one tap away in its app bar (a dot while one runs). A chat
/// keeps the whole screen: no tab bar under its input.
class AssistantPage extends StatefulWidget {
  const AssistantPage({super.key, required this.session, required this.log, required this.routineAgent,
    this.startOnRoutines = false});

  final RobotSession session;
  /// The assistant's history, kept by the workspace.
  final AuditLog log;
  /// Runs routines (the workspace's, so a run goes on after this screen closes).
  final RobotAgent routineAgent;
  /// Opens the routines at once (one is running).
  final bool startOnRoutines;

  @override
  State<AssistantPage> createState() => _AssistantPageState();
}

class _AssistantPageState extends State<AssistantPage> {
  @override
  void initState() {
    super.initState();
    if (widget.startOnRoutines) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ToolTabs.splitAxis(MediaQuery.sizeOf(context)) == null) {
        _openRoutines();
      }
      });
    }
  }

  void _openRoutines() {
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RoutinesPage(book: widget.session.routines,
        agent: widget.routineAgent, prepare: widget.session.prepare)));
  }

  @override
  Widget build(BuildContext context) => ToolTabs(title: context.strings.aiRoutines, phoneTabs: false, tabs: [
    ToolTab(key: const Key('assistant-pane'), label: context.strings.assistant, icon: Icons.smart_toy_outlined,
      build: (_) => AgentPage(session: widget.session, log: widget.log, extraActions: [
    ListenableBuilder(listenable: widget.routineAgent, builder: (context, _) =>
      ToolTabsScope.maybeOf(context)?.split == true ? const SizedBox.shrink() : IconButton(
      key: const Key('open-routines'), tooltip: context.strings.routines, onPressed: _openRoutines,
      icon: Badge(isLabelVisible: widget.routineAgent.progress != null, smallSize: 8,
        child: const Icon(Icons.playlist_play)))),
    ])),
    ToolTab(key: const Key('routines-pane'), label: context.strings.routines, icon: Icons.playlist_play,
      build: (_) => RoutinesPage(book: widget.session.routines, agent: widget.routineAgent, prepare: widget.session.prepare)),
  ]);
}
