import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'app_language.dart';
import 'app_theme.dart';
import 'incident_recorder.dart';

/// Saved incident records, newest first, with "save the last 5 minutes now".
class IncidentsPage extends StatefulWidget {
  const IncidentsPage({super.key, required this.store, this.saveNow});

  final IncidentStore store;
  /// Saves what the robot did in the last minutes (null when no robot is connected).
  final Future<Incident?> Function()? saveNow;

  @override
  State<IncidentsPage> createState() => _IncidentsPageState();
}

class _IncidentsPageState extends State<IncidentsPage> {
  List<Incident>? incidents;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    List<Incident> list;
    try {
      list = await widget.store.list();
    } catch (_) {
      list = const []; // unreadable storage: show none rather than spin
    }
    if (mounted) setState(() => incidents = list);
  }

  Future<void> _save() async {
    final saved = await widget.saveNow?.call();
    if (!mounted) return;
    await _load();
    if (saved != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.incidentSaved)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = incidents;
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.incidentRecords)),
      floatingActionButton: widget.saveNow == null ? null : FloatingActionButton.extended(
        key: const Key('incident-save-now'), onPressed: _save,
        icon: const Icon(Icons.save_alt), label: Text(context.strings.saveLastMinutes)),
      body: list == null ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(context.strings.incidentHint, style: TextStyle(color: context.muted)),
          const SizedBox(height: 12),
          if (list.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text(context.strings.noIncidents, style: TextStyle(color: context.muted)))),
          for (final i in list) Card(child: ListTile(
            key: Key('incident-${i.id}'),
            leading: Icon(_reasonIcon(i), color: _hasError(i) ? const Color(0xFFB3261E) : null),
            title: Text(i.reason, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${i.robot} · ${_when(i.time)} · ${context.strings.eventsCount(i.events.length)}'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) =>
                IncidentPage(incident: i, onDelete: () => widget.store.delete(i.id))));
              _load();
            })),
        ]),
    );
  }

  static bool _hasError(Incident i) => i.events.any((e) => e.level == 'error' || e.kind == IncidentKind.link);
  static IconData _reasonIcon(Incident i) => _hasError(i) ? Icons.report_outlined : Icons.history;
}

String _when(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';
String _two(int n) => n.toString().padLeft(2, '0');

/// One record: the path, a time slider to step through it, and the events up to that moment.
class IncidentPage extends StatefulWidget {
  const IncidentPage({super.key, required this.incident, this.onDelete});

  final Incident incident;
  final Future<void> Function()? onDelete;

  @override
  State<IncidentPage> createState() => _IncidentPageState();
}

class _IncidentPageState extends State<IncidentPage> {
  late double at = widget.incident.events.isEmpty ? 0 : (widget.incident.events.length - 1).toDouble();

  @override
  Widget build(BuildContext context) {
    final i = widget.incident;
    final events = i.events;
    final upTo = events.isEmpty ? -1 : at.round();
    final shown = [for (var k = upTo; k >= 0 && k > upTo - 200; k--) if (events[k].kind != IncidentKind.pose) events[k]];
    return Scaffold(
      appBar: AppBar(title: Text(i.reason, maxLines: 1, overflow: TextOverflow.ellipsis), actions: [
        IconButton(key: const Key('incident-copy'), tooltip: context.strings.copyRecord, icon: const Icon(Icons.copy),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent(' ').convert(i.toJson())));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.copied)));
          }),
        if (widget.onDelete != null) IconButton(key: const Key('incident-delete'), tooltip: context.strings.delete,
          icon: const Icon(Icons.delete_outline), onPressed: () async {
            await widget.onDelete!();
            if (context.mounted) Navigator.of(context).pop();
          }),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), children: [
        Text('${i.robot} · ${_when(i.time)}', style: TextStyle(color: context.muted)),
        const SizedBox(height: 12),
        AspectRatio(aspectRatio: 1.4, child: Card(margin: EdgeInsets.zero, clipBehavior: Clip.antiAlias,
          child: CustomPaint(key: const Key('incident-path'), painter: _PathPainter(events, upTo,
            ink: context.ink, muted: context.muted)))),
        if (events.length > 1) ...[
          Slider(key: const Key('incident-time'), min: 0, max: (events.length - 1).toDouble(), value: at,
            onChanged: (v) => setState(() => at = v)),
          Text(_when(events[upTo].time), textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
        ],
        const SizedBox(height: 8),
        if (shown.isEmpty) Padding(padding: const EdgeInsets.all(16),
          child: Text(context.strings.noEventsYet, style: TextStyle(color: context.muted))),
        for (final e in shown) ListTile(dense: true, contentPadding: EdgeInsets.zero,
          leading: Icon(_icon(e), size: 20, color: e.level == 'error' ? const Color(0xFFB3261E)
              : e.level == 'warning' ? const Color(0xFFB26A00) : context.muted),
          title: Text(e.text, maxLines: 3, overflow: TextOverflow.ellipsis),
          subtitle: Text('${_two(e.time.hour)}:${_two(e.time.minute)}:${_two(e.time.second)}'
              '${e.x == null ? '' : ' · (${e.x!.toStringAsFixed(2)}, ${e.y!.toStringAsFixed(2)})'}')),
      ]),
    );
  }

  static IconData _icon(IncidentEvent e) => switch (e.kind) {
    IncidentKind.command => Icons.gamepad_outlined,
    IncidentKind.nav => Icons.flag_outlined,
    IncidentKind.ai => Icons.smart_toy_outlined,
    IncidentKind.log => Icons.receipt_long_outlined,
    IncidentKind.link => Icons.link_off,
    IncidentKind.notice => Icons.notifications_outlined,
    IncidentKind.mark => Icons.bookmark_outline,
    IncidentKind.pose => Icons.place_outlined,
  };
}

/// The robot's path up to [upTo]: grey ahead, ink behind, a dot where it was, red marks for errors.
class _PathPainter extends CustomPainter {
  _PathPainter(this.events, this.upTo, {required this.ink, required this.muted});

  final List<IncidentEvent> events;
  final int upTo;
  final Color ink, muted;

  @override
  void paint(Canvas canvas, Size size) {
    final points = [for (var k = 0; k < events.length; k++) if (events[k].x != null) (k, events[k].x!, events[k].y!)];
    if (points.isEmpty) return;
    var minX = points.map((p) => p.$2).reduce(math.min), maxX = points.map((p) => p.$2).reduce(math.max);
    var minY = points.map((p) => p.$3).reduce(math.min), maxY = points.map((p) => p.$3).reduce(math.max);
    final span = math.max(math.max(maxX - minX, maxY - minY), 1.0); // at least 1 m across
    final cx = (minX + maxX) / 2, cy = (minY + maxY) / 2;
    minX = cx - span / 2; maxX = cx + span / 2; minY = cy - span / 2; maxY = cy + span / 2;
    final scale = math.min(size.width, size.height) * 0.85 / span;
    Offset at(double x, double y) => Offset(size.width / 2 + (x - cx) * scale, size.height / 2 - (y - cy) * scale);
    final poses = [for (final p in points) if (events[p.$1].kind == IncidentKind.pose) p];
    Paint line(Color c) => Paint()..color = c..strokeWidth = 2.5..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    for (var k = 1; k < poses.length; k++) {
      canvas.drawLine(at(poses[k - 1].$2, poses[k - 1].$3), at(poses[k].$2, poses[k].$3),
          line(poses[k].$1 <= upTo ? ink : muted.withValues(alpha: 0.4)));
    }
    for (final p in points) {
      final e = events[p.$1];
      if (p.$1 > upTo || (e.level != 'error' && e.kind != IncidentKind.link)) continue;
      canvas.drawCircle(at(p.$2, p.$3), 5, Paint()..color = const Color(0xFFB3261E));
    }
    final here = points.lastWhere((p) => p.$1 <= upTo, orElse: () => points.first);
    canvas.drawCircle(at(here.$2, here.$3), 7, Paint()..color = const Color(0xFF00897B));
  }

  @override
  bool shouldRepaint(_PathPainter old) => old.upTo != upTo || old.events != events;
}
