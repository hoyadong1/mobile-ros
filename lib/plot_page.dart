import 'app_language.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'plotting.dart';
import 'ros_connection.dart';

/// A live graph of one topic's values over time, full screen. Several fields can share it; each can
/// be hidden; the time window, pausing and min/max/average are one tap away. Takes the place of
/// PlotJuggler / rqt_plot on a PC.
class PlotPage extends StatefulWidget {
  const PlotPage({super.key, required this.connection, required this.topic, required this.fields,
    this.title, this.clock = DateTime.now, this.throttleMs = 50});
  final RosConnection connection;
  final String topic;
  final List<PlotField> fields;
  final String? title;
  final DateTime Function() clock;
  /// Minimum time between messages (50 ms = up to 20 Hz; large messages such as scans want more).
  final int throttleMs;

  @override
  State<PlotPage> createState() => PlotPageState();
}

const _colors = [Color(0xFF087F8C), Color(0xFFE5743A), Color(0xFF6A5ACD), Color(0xFF2E7D32),
  Color(0xFFC2185B), Color(0xFF8D6E63)];

class PlotPageState extends State<PlotPage> {
  static const windows = [Duration(seconds: 10), Duration(seconds: 30), Duration(minutes: 1), Duration(minutes: 5)];

  final buffer = PlotBuffer();
  late final List<PlotField> fields = List.of(widget.fields);
  final hidden = <String>{};
  Duration window = const Duration(seconds: 30);
  bool paused = false;
  DateTime? frozenAt;
  Map? latest;
  StreamSubscription? _sub;
  Timer? _frame;
  late final String _id = 'plot_${identityHashCode(this)}';

  @override
  void initState() {
    super.initState();
    _sub = widget.connection.messages.listen((e) {
      if (e['op'] != 'publish' || e['topic'] != widget.topic) return;
      final msg = e['msg'];
      if (msg is! Map) return;
      latest = msg;
      buffer.add(widget.clock(), msg, fields);
    });
    try {
      // Its own subscription, whatever the screen underneath subscribed with.
      widget.connection.send({'op': 'subscribe', 'id': _id, 'topic': widget.topic,
        'throttle_rate': widget.throttleMs, 'queue_length': 1});
    } catch (_) {}
    // Redraw 5 times a second rather than per message.
    _frame = Timer.periodic(const Duration(milliseconds: 200), (_) { if (mounted && !paused) setState(() {}); });
  }

  @override
  void dispose() {
    _frame?.cancel();
    _sub?.cancel();
    try { widget.connection.send({'op': 'unsubscribe', 'id': _id, 'topic': widget.topic}); } catch (_) {}
    super.dispose();
  }

  String _fmt(double v) => v.abs() >= 1000 ? v.toStringAsFixed(0)
      : v.abs() >= 100 ? v.toStringAsFixed(1) : v.abs() >= 1 ? v.toStringAsFixed(2) : v.toStringAsFixed(3);

  String _windowLabel(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes} min' : '${d.inSeconds} s';

  Future<void> _addField() async {
    final msg = latest;
    if (msg == null) return;
    final have = fields.map((f) => f.id).toSet();
    final options = numericFields(msg).keys.where((p) => !have.contains(pathField(p).id)).toList()..sort();
    final picked = await showModalBottomSheet<String>(context: context, isScrollControlled: true, showDragHandle: true,
      builder: (context) => _FieldPicker(options: options));
    if (picked == null || !mounted) return;
    setState(() => fields.add(pathField(picked)));
  }

  @override
  Widget build(BuildContext context) {
    final now = paused ? (frozenAt ?? widget.clock()) : widget.clock();
    final shown = [for (final f in fields) if (!hidden.contains(f.id)) f];
    final lines = <LineChartBarData>[];
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final f in shown) {
      final pts = buffer.points(f.id, now, window);
      for (final p in pts) {
        lo = math.min(lo, p.$2);
        hi = math.max(hi, p.$2);
      }
      lines.add(LineChartBarData(
        spots: [for (final p in pts) FlSpot(p.$1, p.$2)],
        color: _colors[fields.indexOf(f) % _colors.length], barWidth: 2, isCurved: false,
        dotData: const FlDotData(show: false)));
    }
    final hasData = lo.isFinite;
    if (hasData) {
      // A minimum visible span, so sensor noise (a few millimetres) is not blown up into a dramatic graph.
      final mid = (hi + lo) / 2;
      final units = {for (final f in shown) f.unit};
      final minSpan = units.length == 1 ? switch (units.first) {
        '°/s' => 10.0, 'm/s' => 0.2, 'm' => 0.5, 'V' => 0.5, '°' => 10.0, '%' => 10.0, 'A' => 0.5, '°C' => 2.0,
        _ => math.max(mid.abs() * 0.1, 1e-3),
      } : math.max(mid.abs() * 0.1, 1e-3);
      if (hi - lo < minSpan) { lo = mid - minSpan / 2; hi = mid + minSpan / 2; }
    }
    final pad = hasData ? (hi - lo) * 0.1 : 0.0;
    final seconds = window.inMicroseconds / 1e6;

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.title ?? context.strings.graph),
          Text(widget.topic, style: TextStyle(fontSize: 12, color: context.muted)),
        ]),
        actions: [
          IconButton(key: const Key('plot-pause'), tooltip: paused ? 'Resume' : 'Pause',
            icon: Icon(paused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() { paused = !paused; frozenAt = paused ? widget.clock() : null; })),
          IconButton(key: const Key('plot-clear'), tooltip: context.strings.clear, icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => setState(buffer.clear)),
        ],
      ),
      body: SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), child: Column(children: [
        SegmentedButton<Duration>(key: const Key('plot-window'), showSelectedIcon: false,
          segments: [for (final w in windows) ButtonSegment(value: w, label: Text(_windowLabel(w)))],
          selected: {window}, onSelectionChanged: (s) => setState(() => window = s.first)),
        const SizedBox(height: 12),
        Expanded(child: !hasData
            ? Center(child: Text(latest == null ? context.strings.waitingOnTopic(widget.topic) : context.strings.noNumbersYet,
                key: const Key('plot-waiting'), style: TextStyle(color: context.muted)))
            : LineChart(duration: Duration.zero, LineChartData(
                minX: -seconds, maxX: 0, minY: lo - pad, maxY: hi + pad,
                clipData: const FlClipData.all(),
                gridData: FlGridData(drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) => FlLine(color: context.border, strokeWidth: 1)),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(), rightTitles: const AxisTitles(),
                  leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 52,
                    getTitlesWidget: (v, meta) => v == meta.max || v == meta.min ? const SizedBox()
                        : Text(_fmt(v), style: TextStyle(fontSize: 11, color: context.muted)))),
                  bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22,
                    interval: seconds / 4,
                    getTitlesWidget: (v, meta) => Text(v == 0 ? 'now' : '${(-v).round()} s',
                      style: TextStyle(fontSize: 11, color: context.muted)))),
                ),
                lineTouchData: LineTouchData(touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => [for (final s in spots) LineTooltipItem(
                    '${_fmt(s.y)} ${shown[s.barIndex].unit}  (${(-s.x).toStringAsFixed(1)} s ago)',
                    TextStyle(color: s.bar.color, fontWeight: FontWeight.w700, fontSize: 12))])),
                lineBarsData: lines,
              ))),
        const SizedBox(height: 12),
        for (var i = 0; i < fields.length; i++) _legend(fields[i], i, now),
        Align(alignment: Alignment.centerLeft, child: TextButton.icon(key: const Key('plot-add'),
          onPressed: latest == null ? null : _addField, icon: const Icon(Icons.add, size: 18),
          label: Text(context.strings.addAnotherValue))),
        if (paused) Text(context.strings.graphPaused,
          style: TextStyle(fontSize: 12, color: context.muted)),
      ]))),
    );
  }

  Widget _legend(PlotField f, int i, DateTime now) {
    final off = hidden.contains(f.id);
    final st = buffer.stats(f.id, now, window);
    final color = _colors[i % _colors.length];
    final unit = f.unit.isEmpty ? '' : ' ${f.unit}';
    return InkWell(key: Key('plot-legend-${f.label}'), borderRadius: BorderRadius.circular(10),
      onTap: () => setState(() => off ? hidden.remove(f.id) : hidden.add(f.id)),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4), child: Row(children: [
        Container(width: 14, height: 14, decoration: BoxDecoration(
          color: off ? Colors.transparent : color, border: Border.all(color: color, width: 2),
          borderRadius: BorderRadius.circular(4))),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, color: off ? context.muted : context.ink)),
          if (st != null) Text('min ${_fmt(st.min)} · max ${_fmt(st.max)} · avg ${_fmt(st.mean)}$unit',
            style: TextStyle(fontSize: 12, color: context.muted)),
        ])),
        Text(st == null ? '—' : '${_fmt(st.last)}$unit', key: Key('plot-value-${f.label}'),
          style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: off ? context.muted : color,
            fontFeatures: const [FontFeature.tabularFigures()])),
        if (fields.length > 1) IconButton(tooltip: context.strings.remove, visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() { fields.removeAt(i); hidden.remove(f.id); })),
      ])));
  }
}

class _FieldPicker extends StatefulWidget {
  const _FieldPicker({required this.options});
  final List<String> options;

  @override
  State<_FieldPicker> createState() => _FieldPickerState();
}

class _FieldPickerState extends State<_FieldPicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final shown = [for (final o in widget.options) if (q.isEmpty || o.toLowerCase().contains(q)) o];
    return SizedBox(height: MediaQuery.sizeOf(context).height * 0.7, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(key: const Key('plot-field-search'),
        decoration: InputDecoration(prefixIcon: Icon(Icons.search), hintText: context.strings.searchValues),
        onChanged: (v) => setState(() => query = v.trim()))),
      Expanded(child: shown.isEmpty ? Center(child: Text(context.strings.noNumbersInMessage, style: TextStyle(color: context.muted)))
          : ListView.builder(itemCount: shown.length, itemBuilder: (context, i) => ListTile(
              dense: true, title: Text(shown[i], style: const TextStyle(fontFamily: 'monospace')),
              onTap: () => Navigator.pop(context, shown[i])))),
    ]));
  }
}

/// Picks a numeric field of [msg] to graph (for screens that show raw messages).
Future<String?> pickPlotField(BuildContext context, Map msg) => showModalBottomSheet<String>(
  context: context, isScrollControlled: true, showDragHandle: true,
  builder: (_) => _FieldPicker(options: numericFields(msg).keys.toList()..sort()));
