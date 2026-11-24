import 'dart:async';

import 'package:material_ui/material_ui.dart';

import 'app_language.dart';
import 'app_theme.dart';
import 'diagnostics.dart';
import 'ros_connection.dart';
import 'widgets/throttled_rebuild.dart';

Color diagColor(BuildContext context, DiagLevel l) => switch (l) {
  DiagLevel.ok => const Color(0xFF00897B),
  DiagLevel.warn => const Color(0xFFB26A00),
  DiagLevel.error => const Color(0xFFB3261E),
  DiagLevel.stale => context.muted,
};

String diagLabel(BuildContext context, DiagLevel l) => switch (l) {
  DiagLevel.ok => context.strings.healthOk,
  DiagLevel.warn => context.strings.diagWarn,
  DiagLevel.error => context.strings.diagError,
  DiagLevel.stale => context.strings.diagStale,
};

/// What the robot says about its own parts (/diagnostics or /diagnostics_agg): worst first, each with
/// its message and details.
class DiagnosticsPage extends StatefulWidget {
  const DiagnosticsPage({super.key, required this.connection, required this.topic, this.clock = DateTime.now});

  final RosConnection connection;
  final String topic;
  final DateTime Function() clock;

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> with ThrottledRebuild {
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 500);

  final board = DiagnosticsBoard();
  StreamSubscription? _sub;
  Timer? _ticker;
  bool problemsOnly = false;
  static int _instances = 0;
  final _id = 'diagnostics-${_instances++}';

  @override
  void initState() {
    super.initState();
    _sub = widget.connection.messages.listen((e) {
      if (e['op'] != 'publish' || e['topic'] != widget.topic) return;
      board.update(e['msg'], widget.clock());
      rebuildSoon();
    });
    try {
      widget.connection.send({'op': 'subscribe', 'id': _id, 'topic': widget.topic, 'throttle_rate': 500, 'queue_length': 1});
    } catch (_) {}
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    try { widget.connection.send({'op': 'unsubscribe', 'id': _id, 'topic': widget.topic}); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final now = widget.clock();
    final counts = board.counts(now);
    final all = board.sorted(now);
    final shown = problemsOnly ? all.where((d) => board.levelOf(d, now) != DiagLevel.ok).toList() : all;
    final worst = counts[DiagLevel.error]! > 0 ? DiagLevel.error : counts[DiagLevel.warn]! > 0 ? DiagLevel.warn
        : counts[DiagLevel.stale]! > 0 ? DiagLevel.stale : DiagLevel.ok;
    return Scaffold(
      appBar: AppBar(title: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
        child: Text(s.robotDiagnostics))),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text(widget.topic, style: TextStyle(color: context.muted)),
        const SizedBox(height: 8),
        if (board.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 32),
          child: Center(child: Text(s.waitingMessages, style: TextStyle(color: context.muted))))
        else ...[
          Card(key: const Key('diag-summary'), margin: EdgeInsets.zero, child: Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Icon(worst == DiagLevel.ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                color: diagColor(context, worst)),
              for (final l in [DiagLevel.error, DiagLevel.warn, DiagLevel.stale, DiagLevel.ok])
                if (counts[l]! > 0) Text('${diagLabel(context, l)} ${counts[l]}', key: Key('diag-count-${l.name}'),
                  style: TextStyle(color: diagColor(context, l), fontWeight: FontWeight.w700)),
            ]))),
          const SizedBox(height: 8),
          SwitchListTile(key: const Key('diag-problems-only'), contentPadding: EdgeInsets.zero,
            title: Text(s.diagProblemsOnly), value: problemsOnly, onChanged: (v) => setState(() => problemsOnly = v)),
          if (shown.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text(s.diagNoProblems, style: TextStyle(color: context.muted)))),
          for (final d in shown) _tile(context, d, board.levelOf(d, now)),
          const SizedBox(height: 8),
          Text(s.diagnosticsHint, style: TextStyle(fontSize: 12, color: context.muted)),
        ],
      ]),
    );
  }

  Widget _tile(BuildContext context, DiagStatus d, DiagLevel level) {
    final color = diagColor(context, level);
    return Card(key: Key('diag-${d.name}'), margin: const EdgeInsets.only(bottom: 8), clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        shape: const Border(), collapsedShape: const Border(),
        leading: Icon(Icons.circle, size: 12, color: color),
        title: Text(d.shortName, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (d.group.isNotEmpty) Text(d.group, style: TextStyle(fontSize: 12, color: context.muted)),
          if (d.message.isNotEmpty) Text(d.message, style: TextStyle(color: level == DiagLevel.ok ? null : color)),
        ]),
        trailing: Text(diagLabel(context, level), key: Key('diag-level-${d.name}'),
          style: TextStyle(color: color, fontWeight: FontWeight.w700)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (d.hardwareId.isNotEmpty) _kv(context, 'hardware_id', d.hardwareId),
          for (final (k, v) in d.values) _kv(context, k, v),
        ]),
    );
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(flex: 2, child: Text(k, style: TextStyle(color: context.muted))),
      const SizedBox(width: 8),
      Expanded(flex: 3, child: SelectableText(v)),
    ]));
}
