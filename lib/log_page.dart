import 'app_language.dart';
import 'widgets/readable_width.dart';
import 'package:flutter/services.dart';
import 'tool_tabs.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'robot_log.dart';

/// The robot's log, made for a phone: problems first to find, repeats folded, one tap for details.
/// Takes the place of rqt_console / `ros2 topic echo /rosout` on a PC.
class RobotLogPage extends StatefulWidget {
  const RobotLogPage({super.key, required this.log});
  final RobotLog log;

  @override
  State<RobotLogPage> createState() => _RobotLogPageState();
}

class _RobotLogPageState extends State<RobotLogPage> {
  LogFilter filter = LogFilter.all;
  String? node;
  String query = '';
  bool searching = false;
  /// While paused the list stays still for reading; lines keep being collected.
  List<LogEntry>? frozen;

  RobotLog get log => widget.log;

  @override
  void initState() {
    super.initState();
    log.addListener(_onLog);
    // Opening the log is looking at its problems.
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted && _visible) log.markSeen(); });
    // With problems waiting, start on them.
    if (log.unseenProblems > 0) filter = LogFilter.warnings;
  }

  @override
  void dispose() {
    log.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (!mounted) return;
    if (_visible && log.unseenProblems > 0) log.markSeen();
    setState(() {});
  }

  bool get _visible => ToolTabsScope.maybeOf(context)?.visible ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible) log.markSeen();
      });
    }
  }

  List<LogEntry> get _shown => [
    for (final e in frozen ?? log.entries)
      if (logFilterMatches(filter, e, node: node, query: query)) e,
  ];

  Future<void> _copy(List<LogEntry> lines) async {
    await Clipboard.setData(ClipboardData(text: [for (final e in lines.reversed) e.toLine()].join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.strings.copiedLines(lines.length))));
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    final counts = log.problems;
    final paused = frozen != null;
    final newWhilePaused = paused ? log.entries.length - frozen!.length : 0;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        title: searching
            ? TextField(key: const Key('log-search'), autofocus: true,
                decoration: InputDecoration(hintText: context.strings.searchLog, border: InputBorder.none,
                  filled: false, contentPadding: EdgeInsets.zero),
                onChanged: (v) => setState(() => query = v.trim()))
            : Text(ToolTabsScope.maybeOf(context)?.title ?? context.strings.log),
        bottom: ToolTabsScope.maybeOf(context)?.bar,
        actions: [
          IconButton(key: const Key('log-search-toggle'), tooltip: searching ? context.strings.closeSearch : context.strings.search,
            icon: Icon(searching ? Icons.close : Icons.search),
            onPressed: () => setState(() { searching = !searching; if (!searching) query = ''; })),
          IconButton(key: const Key('log-pause'), tooltip: paused ? 'Resume' : 'Pause',
            icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => frozen = paused ? null : List.of(log.entries))),
          PopupMenuButton<String>(key: const Key('log-menu'), onSelected: (v) {
            if (v == 'copy') _copy(shown);
            if (v == 'clear') setState(() { log.clear(); frozen = null; });
          }, itemBuilder: (_) => [
            PopupMenuItem(value: 'copy', enabled: shown.isNotEmpty,
              child: ListTile(leading: const Icon(Icons.copy), title: Text(context.strings.copyShownLines))),
            PopupMenuItem(value: 'clear',
              child: ListTile(leading: const Icon(Icons.delete_outline), title: Text(context.strings.clear))),
          ]),
        ],
      ),
      body: ReadableWidth(maxWidth: 900, child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Row(children: [
          Expanded(child: SegmentedButton<LogFilter>(
            key: const Key('log-filter'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: LogFilter.all, label: _fit(context.strings.all)),
              ButtonSegment(value: LogFilter.warnings, label: _fit(counts.warnings + counts.errors == 0
                ? context.strings.problems : context.strings.problemsCount(counts.warnings + counts.errors))),
              ButtonSegment(value: LogFilter.errors, label: _fit(
                counts.errors == 0 ? context.strings.errors : context.strings.errorsCount(counts.errors))),
            ],
            selected: {filter},
            onSelectionChanged: (s) => setState(() => filter = s.first),
          )),
        ])),
        if (log.nodes.length > 1 || node != null)
          SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16), children: [
              Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                key: const Key('log-node-all'), label: Text(context.strings.allNodes), selected: node == null,
                onSelected: (_) => setState(() => node = null))),
              for (final n in log.nodes)
                Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(
                  label: Text(n.isEmpty ? '(no name)' : n), selected: node == n,
                  onSelected: (on) => setState(() => node = on ? n : null))),
            ])),
        if (paused)
          Material(color: Theme.of(context).colorScheme.secondaryContainer, child: ListTile(
            key: const Key('log-paused'), dense: true,
            leading: const Icon(Icons.pause_circle_outline),
            title: Text(newWhilePaused > 0 ? context.strings.pausedNew(newWhilePaused) : context.strings.paused),
            trailing: TextButton(onPressed: () => setState(() => frozen = null), child: Text(context.strings.resume)))),
        Expanded(child: shown.isEmpty ? _empty() : ListView.separated(
          key: const Key('log-list'),
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
          itemCount: shown.length,
          separatorBuilder: (_, _) => const SizedBox(height: 6),
          itemBuilder: (context, i) => _row(shown[i]),
        )),
      ])),
    );
  }

  /// One line per filter, shrunk if needed: at large text sizes a word must not break across lines.
  Widget _fit(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1));

  Widget _empty() {
    final (icon, title, text) = !log.heard
        ? (Icons.hourglass_empty, context.strings.listeningLog, context.strings.listeningLogHint)
        : query.isNotEmpty || node != null
            ? (Icons.search_off, context.strings.nothingMatches, context.strings.tryAnother)
            : filter == LogFilter.all
                ? (Icons.inbox_outlined, context.strings.noLogLines, context.strings.clearedHint)
                : (Icons.check_circle_outline, context.strings.noProblems,
                    filter == LogFilter.errors ? context.strings.noErrorsSince : context.strings.noWarningsSince);
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 48, color: context.muted),
      const SizedBox(height: 12),
      Text(title, key: const Key('log-empty'), textAlign: TextAlign.center,
        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: context.ink)),
      const SizedBox(height: 6),
      Text(text, textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
    ])));
  }

  (IconData, Color) _look(LogLevel level) {
    final cs = Theme.of(context).colorScheme;
    return switch (level) {
      LogLevel.fatal || LogLevel.error => (Icons.error, cs.error),
      LogLevel.warn => (Icons.warning_amber_rounded, context.isDark ? const Color(0xFFFFB74D) : const Color(0xFFB26A00)),
      LogLevel.info => (Icons.info_outline, context.muted),
      LogLevel.debug => (Icons.bug_report_outlined, context.muted),
    };
  }

  Widget _row(LogEntry e) {
    final (icon, color) = _look(e.level);
    final problem = e.level.isProblem;
    return Material(
      color: problem ? color.withValues(alpha: context.isDark ? 0.14 : 0.07) : context.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: problem ? color.withValues(alpha: 0.35) : context.border)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(onTap: () => _details(e), child: Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, color: color, size: 20)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(e.node.isEmpty ? '(no name)' : e.node, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: context.ink))),
              if (e.count > 1) Container(
                key: const Key('log-repeat'),
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8)),
                child: Text('×${e.count}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: context.ink))),
              const SizedBox(width: 8),
              Text(LogEntry.clock(e.time), style: TextStyle(fontSize: 12, color: context.muted,
                fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
            const SizedBox(height: 2),
            Text(e.text, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 14, height: 1.3, color: context.ink)),
          ])),
        ]))),
    );
  }

  void _details(LogEntry e) {
    final (icon, color) = _look(e.level);
    showModalBottomSheet<void>(context: context, isScrollControlled: true, showDragHandle: true,
      builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 8),
            Text(e.level.label, style: TextStyle(fontWeight: FontWeight.w800, color: color)),
            const Spacer(),
            Text(e.count > 1 ? '${e.count} times, last at ${LogEntry.clock(e.time)}' : LogEntry.clock(e.time),
              style: TextStyle(color: context.muted)),
          ]),
          const SizedBox(height: 8),
          Text(e.node, style: TextStyle(fontWeight: FontWeight.w700, color: context.ink)),
          const SizedBox(height: 8),
          ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
            child: SingleChildScrollView(child: SelectableText(e.text, key: const Key('log-detail-text'),
              style: TextStyle(fontSize: 15, height: 1.4, color: context.ink)))),
          if (e.file.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(
            '${e.file}${e.line > 0 ? ':${e.line}' : ''}${e.function.isNotEmpty ? ' · ${e.function}' : ''}',
            style: TextStyle(fontSize: 12, color: context.muted))),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(icon: const Icon(Icons.copy, size: 18), label: Text(context.strings.copy),
              onPressed: () { Navigator.pop(context); _copy([e]); }),
            if (node != e.node) OutlinedButton.icon(icon: const Icon(Icons.filter_alt_outlined, size: 18),
              label: Text(context.strings.onlyThisNode),
              onPressed: () { Navigator.pop(context); setState(() => node = e.node); }),
          ]),
        ]))));
  }
}
