import '../app_language.dart';
import 'package:material_ui/material_ui.dart';
import '../navigation_goal.dart' show RosVersion;
import '../robot_profile.dart';
import '../robot_session.dart';
import '../robot_summary.dart';

/// "This robot": what was found when connecting — what kind of robot it is, what it can sense and do,
/// and what the AI assistant can do with it. Tap for where each item was found.
class RobotSummaryCard extends StatefulWidget {
  const RobotSummaryCard({super.key, required this.session, required this.connectionKind});

  final RobotSession session;
  /// How the app is connected, e.g. "rosbridge", "DDS", "Zenoh".
  final String connectionKind;

  @override
  State<RobotSummaryCard> createState() => _RobotSummaryCardState();
}

class _RobotSummaryCardState extends State<RobotSummaryCard> {
  late Future<RobotSummary> _summary = _load();

  Future<RobotSummary> _load() async {
    final s = widget.session;
    final caps = await s.capabilities();
    final profile = s.drive.profile ?? await ProfileStore.loadAt(s.storeAddress);
    return RobotSummary.from(caps, profile: profile);
  }

  void _refresh() {
    widget.session.invalidate();
    setState(() => _summary = _load());
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<RobotSummary>(
    future: _summary,
    builder: (context, snap) {
      final theme = Theme.of(context);
      final Widget body;
      if (snap.connectionState != ConnectionState.done) {
        body = Row(children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Expanded(child: Text(context.strings.findingOut)),
        ]);
      } else if (snap.hasError || snap.data == null) {
        body = Text(context.strings.summaryError('${snap.error}'));
      } else {
        body = _content(context, snap.data!);
      }
      return Card(key: const Key('robot-summary'), margin: EdgeInsets.zero, child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.smart_toy_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(context.strings.thisRobot, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
            IconButton(tooltip: context.strings.lookAgain, icon: const Icon(Icons.refresh), onPressed: _refresh),
          ]),
          const SizedBox(height: 8),
          body,
        ])));
    },
  );

  Widget _content(BuildContext context, RobotSummary s) {
    final muted = TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13);
    if (!s.discovered) {
      return Text(context.strings.noDescription, style: muted);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text([s.model, s.kindIn(context.strings)].whereType<String>().join(' · '),
          key: const Key('robot-summary-kind'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      Text(context.strings.summaryCounts(s.rosVersion == RosVersion.ros1 ? 'ROS 1' : 'ROS 2', widget.connectionKind,
          s.topicCount, s.nodeCount, s.actionCount), style: muted),
      const SizedBox(height: 12),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final f in s.features)
          if (f.detected || const {'drive', 'navigation', 'camera', 'lidar'}.contains(f.id))
            ActionChip(
              key: Key('robot-feature-${f.id}'),
              avatar: Icon(f.detected ? Icons.check_circle : Icons.remove_circle_outline, size: 18,
                  color: f.detected ? const Color(0xFF2E7D32) : const Color(0xFF9AA5B1)),
              label: Text(f.labelIn(context.strings), style: TextStyle(color: f.detected ? null : const Color(0xFF7A8794))),
              onPressed: () => _showWhere(context, f),
            ),
      ]),
      const SizedBox(height: 12),
      Text(context.strings.assistantCanList(s.assistantCan(context.strings).join(', ')), key: const Key('robot-summary-ai'), style: muted),
    ]);
  }

  void _showWhere(BuildContext context, RobotFeature f) => showDialog<void>(context: context, builder: (c) =>
    AlertDialog(
      title: Text(f.labelIn(context.strings)),
      content: Text(f.detected ? context.strings.foundAt(f.topics.join('\n')) : context.strings.notDetected),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: Text(context.strings.ok))],
    ));
}
