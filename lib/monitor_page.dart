import 'app_language.dart';
import 'dart:async';
import 'tool_tabs.dart';
import 'app_theme.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show PointMode;
import 'package:fl_chart/fl_chart.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'message_schema.dart';
import 'plot_page.dart';
import 'plotting.dart';
import 'ros_connection.dart';
import 'sensors.dart';
import 'widgets/throttled_rebuild.dart';

/// Live readings from the robot's sensor topics (battery, LiDAR, IMU, odometry, GPS, range, ...),
/// found automatically through rosapi. Each card shows the latest value, a 30 s trend and whether the
/// topic is still publishing.
class SensorPage extends StatefulWidget {
  const SensorPage({super.key, required this.ip, required this.port, this.connectionFactory = RosConnection.new,
    this.clock = DateTime.now});
  final String ip;
  final String port;
  final RosConnection Function(String, String) connectionFactory;
  /// Injectable for tests (fake time does not move DateTime.now).
  final DateTime Function() clock;

  @override
  State<SensorPage> createState() => SensorPageState();
}

class SensorFeed {
  SensorFeed(this.source);
  final SensorTopic source;
  SensorSample? latest;
  String? error;
  DateTime? lastAt;
  final history = <(DateTime, double)>[];
  final _arrivals = <DateTime>[];

  /// Messages received per second over the last 3 s (capped by the display throttle).
  double rate(DateTime now) {
    final cutoff = now.subtract(const Duration(seconds: 3));
    _arrivals.removeWhere((t) => t.isBefore(cutoff));
    return _arrivals.length / 3;
  }

  void add(SensorSample s, DateTime now) {
    latest = s;
    error = null;
    lastAt = now;
    _arrivals.add(now);
    final v = s.plot;
    if (v != null) history.add((now, v));
    final cutoff = now.subtract(SensorPageState.window);
    history.removeWhere((e) => e.$1.isBefore(cutoff));
  }
}

class SensorPageState extends State<SensorPage> with ThrottledRebuild {
  /// Cards and charts redraw at most 5 times a second, however many feeds are streaming.
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 200);

  static const window = Duration(seconds: 30);
  static const staleAfter = Duration(seconds: 3);

  RosConnection? connection;
  List<SensorFeed>? feeds; // null while discovering
  String? errorMessage;
  Timer? _ticker;
  int _sensorLimit = 16;
  /// Sensor-typed topics hidden because nothing publishes on them.
  int inactiveTopics = 0;
  Map<String, String> _topicTypes = {};
  final List<CustomSensorSource> _customSensors = [];

  @override
  void initState() {
    super.initState();
    _connect();
    // Re-evaluates "stale" and the rate even when a topic goes quiet.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  Future<void> _connect() async {
    try {
      final client = widget.connectionFactory(widget.ip, widget.port);
      connection = client;
      client.messages.listen(_onMessage, onDone: () {
        if (mounted) setState(() => errorMessage = client.lastError ?? context.strings.robotDisconnectedShort);
      });
      await client.ready;
      await _loadCustomSensors();
      await refresh();
    } catch (e) {
      if (mounted) setState(() { errorMessage = context.strings.connectionFailed('$e'); feeds ??= []; });
    }
  }

  /// (Re)discovers sensor topics and subscribes to them.
  Future<void> refresh() async {
    final client = connection;
    if (client == null || client.isClosed) return;
    for (final f in feeds ?? const <SensorFeed>[]) {
      try { client.send({'op': 'unsubscribe', 'topic': f.source.topic}); } catch (_) {}
    }
    setState(() => feeds = null);
    Map<String, dynamic>? topics;
    try {
      topics = await client.call('/rosapi/topics');
    } catch (e) {
      if (mounted) setState(() { errorMessage = context.strings.rosapiListError('$e'); feeds = []; });
      return;
    }
    if (!mounted || client.isClosed) return;
    final names = (topics['topics'] as List?)?.map((value) => '$value').toSet() ?? <String>{};
    final types = (topics['types'] as List?)?.map((value) => '$value').toList() ?? const <String>[];
    final topicTypes = <String, String>{};
    final topicNames = (topics['topics'] as List?)?.map((value) => '$value').toList() ?? const <String>[];
    for (var i = 0; i < topicNames.length && i < types.length; i++) {
      topicTypes[topicNames[i]] = types[i];
    }
    // rosapi also lists topics that only have subscribers (left over from other tools, or the plain
    // /scan next to a namespaced /robot1/scan); they never deliver data, so hide them.
    final candidates = discoverSensors(topics, limit: 1 << 20);
    final found = <SensorTopic>[];
    var inactive = 0;
    for (final s in candidates) {
      if (found.length >= _sensorLimit) break;
      try {
        final publishers = (await client.call('/rosapi/publishers', {'topic': s.topic}))['publishers'];
        if (publishers is List && publishers.isEmpty) { inactive++; continue; }
      } catch (_) {}
      found.add(s);
    }
    if (!mounted || client.isClosed) return;
    for (final custom in _customSensors) {
      if (names.contains(custom.topic)) {
        found.add(SensorTopic(custom.topic, SensorKind.custom, custom.rosType, fieldPath: custom.fieldPath));
      }
    }
    for (final s in found) {
      client.send({'op': 'subscribe', 'topic': s.topic, 'type': s.rosType,
        'throttle_rate': s.kind.throttleMs, 'queue_length': 1});
    }
    setState(() {
      _topicTypes = topicTypes; feeds = [for (final s in found) SensorFeed(s)]; errorMessage = null;
      inactiveTopics = inactive;
    });
  }

  Future<void> _loadCustomSensors() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final limit = prefs.getInt('sensor_topic_limit');
      final raw = prefs.getString('custom_sensor_sources');
      final decoded = raw == null ? null : jsonDecode(raw);
      if (mounted) {
        setState(() {
        if (limit == 16 || limit == 32 || limit == 64) _sensorLimit = limit!;
        if (decoded is List) {
          _customSensors
            ..clear()
            ..addAll(decoded.map(CustomSensorSource.fromJson).whereType<CustomSensorSource>());
        }
      });
      }
    } catch (_) {
      // Sensor monitoring remains available when local preferences are unavailable.
    }
  }

  Future<void> _saveCustomSensors() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('custom_sensor_sources', jsonEncode(_customSensors.map((sensor) => sensor.toJson()).toList()));
  }

  Future<void> _setSensorLimit(int limit) async {
    setState(() => _sensorLimit = limit);
    await refresh();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('sensor_topic_limit', limit);
    } catch (_) {}
  }

  Future<void> _addCustomSensor() async {
    final topics = _topicTypes.keys.toList()..sort();
    if (topics.isEmpty) return;
    String? selectedTopic;
    String? selectedField;
    List<String> fields = [];
    String? fieldsNote;
    var loadingFields = false;
    var request = 0;
    final result = await showDialog<CustomSensorSource>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, updateDialog) {
        // Picking a topic loads its numeric fields right away (no separate button).
        Future<void> pick(String? topic) async {
          if (topic == null) return;
          final mine = ++request;
          updateDialog(() { selectedTopic = topic; selectedField = null; fields = []; fieldsNote = null; loadingFields = true; });
          try {
            final response = await connection!.call('/rosapi/message_details', {'type': _topicTypes[topic]!});
            final found = MessageSchema.fromRosapi(response).numericFieldPaths();
            if (!dialogContext.mounted || mine != request) return;
            updateDialog(() {
              fields = found;
              selectedField = found.firstOrNull;
              loadingFields = false;
              fieldsNote = found.isEmpty ? context.strings.noNumericFields : null;
            });
          } catch (error) {
            if (dialogContext.mounted && mine == request) {
              updateDialog(() { loadingFields = false; fieldsNote = context.strings.fieldsError('$error'); });
            }
          }
        }

        return AlertDialog(
          title: Text(context.strings.addCustomSensor),
          content: SizedBox(width: 480, child: Column(mainAxisSize: MainAxisSize.min, children: [
            Autocomplete<String>(
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                return topics.where((t) => q.isEmpty || t.toLowerCase().contains(q) ||
                    (_topicTypes[t] ?? '').toLowerCase().contains(q)).take(40);
              },
              onSelected: pick,
              fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
                key: const Key('custom-sensor-topic'), controller: controller, focusNode: focus, autofocus: true,
                decoration: InputDecoration(labelText: context.strings.rosTopic, hintText: context.strings.searchTopics,
                  prefixIcon: Icon(Icons.search)),
              ),
            ),
            if (selectedTopic != null) Padding(padding: const EdgeInsets.only(top: 6),
              child: Align(alignment: Alignment.centerLeft, child: Text(normalizeType(_topicTypes[selectedTopic!]!),
                style: TextStyle(fontSize: 12, color: context.muted)))),
            const SizedBox(height: 12),
            if (loadingFields) const LinearProgressIndicator()
            else if (fields.isNotEmpty) DropdownButtonFormField<String>(
              key: ValueKey('$selectedTopic:fields'), initialValue: selectedField, isExpanded: true,
              decoration: InputDecoration(labelText: context.strings.valueToChart),
              items: [for (final field in fields) DropdownMenuItem(value: field, child: Text(field))],
              onChanged: (value) => updateDialog(() => selectedField = value),
            )
            else if (fieldsNote != null) Text(fieldsNote!, style: TextStyle(color: context.muted)),
          ])),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.strings.cancel)),
            FilledButton(
              key: const Key('custom-sensor-add'),
              onPressed: selectedTopic == null || selectedField == null ? null : () {
                Navigator.pop(dialogContext, CustomSensorSource(selectedTopic!, _topicTypes[selectedTopic!]!, selectedField!));
              },
              child: Text(context.strings.addSensor),
            ),
          ],
        );
      }),
    );
    if (result == null || !mounted) return;
    setState(() {
      _customSensors.removeWhere((sensor) => sensor.topic == result.topic && sensor.fieldPath == result.fieldPath);
      _customSensors.add(result);
    });
    try {
      await _saveCustomSensors();
      await refresh();
    } catch (error) {
      setState(() => errorMessage = context.strings.saveSensorError('$error'));
    }
  }

  Future<void> _removeCustomSensor(SensorTopic topic) async {
    setState(() => _customSensors.removeWhere((sensor) => sensor.topic == topic.topic && sensor.fieldPath == topic.fieldPath));
    try {
      await _saveCustomSensors();
      await refresh();
    } catch (error) {
      if (mounted) setState(() => errorMessage = context.strings.removeSensorError('$error'));
    }
  }

  void _onMessage(Map<String, dynamic> event) {
    final list = feeds;
    if (!mounted || list == null || event['op'] != 'publish') return;
    final msg = event['msg'];
    if (msg is! Map) return;
    for (final feed in list) {
      if (feed.source.topic != event['topic']) continue;
      try {
        feed.add(decodeSensor(feed.source.kind, msg, fieldPath: feed.source.fieldPath), widget.clock());
      } catch (e) {
        feed.error = 'Unreadable message: $e'; // shown in the card, kept short
      }
      rebuildSoon();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    connection?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final list = feeds;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        title: Text(ToolTabsScope.maybeOf(context)?.title ?? context.strings.sensors),
        bottom: ToolTabsScope.maybeOf(context)?.bar,
        actions: [
          IconButton(key: const Key('sensors-add-custom'), tooltip: context.strings.addCustomSensor,
            onPressed: list == null || _topicTypes.isEmpty ? null : _addCustomSensor,
            icon: const Icon(Icons.add_chart)),
          PopupMenuButton<int>(key: const Key('sensors-limit'), tooltip: context.strings.sensorTopicLimit,
            onSelected: _setSensorLimit,
            itemBuilder: (_) => [for (final limit in [16, 32, 64])
              CheckedPopupMenuItem(value: limit, checked: _sensorLimit == limit, child: Text(context.strings.showUpToSensors(limit)))]),
          IconButton(key: const Key('sensors-refresh'), tooltip: context.strings.findSensorsAgain,
            onPressed: list == null ? null : refresh, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: SafeArea(child: Column(children: [
        if (errorMessage != null) MaterialBanner(
          content: Text(errorMessage!), leading: const Icon(Icons.error_outline, color: Color(0xFFB3261E)),
          actions: [TextButton(onPressed: () => setState(() => errorMessage = null), child: Text(context.strings.dismiss))]),
        Expanded(child: list == null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                const CircularProgressIndicator(), const SizedBox(height: 16), Text(context.strings.lookingSensors)]))
            : list.isEmpty ? _empty() : _grid(list)),
      ])),
    );
  }

  Widget _empty() => Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(
    mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.sensors_off_outlined, size: 48, color: context.cs.outline),
      const SizedBox(height: 12),
      Text(context.strings.noSensorTopics, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 8),
      OutlinedButton.icon(onPressed: _topicTypes.isEmpty ? null : _addCustomSensor,
        icon: const Icon(Icons.add_chart), label: Text(context.strings.addValueFromTopic)),
    ])));

  Widget _grid(List<SensorFeed> list) => LayoutBuilder(builder: (context, box) {
    final columns = box.maxWidth >= 1100 ? 3 : box.maxWidth >= 640 ? 2 : 1;
    final width = (box.maxWidth - 32 - 12 * (columns - 1)) / columns;
    return SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 12, runSpacing: 12,
          children: [for (final f in list) SizedBox(width: width, child: SensorCard(feed: f, now: widget.clock(),
            onRemove: f.source.kind == SensorKind.custom ? () => _removeCustomSensor(f.source) : null,
            onPlot: connection == null ? null : (field) => Navigator.push(context, MaterialPageRoute(
              builder: (_) => PlotPage(connection: connection!, topic: f.source.topic, title: f.source.kind.label,
                fields: [field])))))]),
        if (inactiveTopics > 0) Padding(padding: const EdgeInsets.only(top: 12), child: Text(
          key: const Key('sensors-inactive'),
          '$inactiveTopics sensor topic${inactiveTopics == 1 ? '' : 's'} with no publisher hidden.',
          style: TextStyle(color: context.muted, fontSize: 12))),
      ]));
  });
}

IconData _icon(SensorKind k) => switch (k) {
  SensorKind.battery => Icons.battery_charging_full,
  SensorKind.laser => Icons.radar,
  SensorKind.imu => Icons.threed_rotation,
  SensorKind.odometry => Icons.speed,
  SensorKind.gps => Icons.satellite_alt_outlined,
  SensorKind.range => Icons.straighten,
  SensorKind.temperature => Icons.thermostat,
  SensorKind.pressure => Icons.compress,
  SensorKind.humidity => Icons.water_drop_outlined,
  SensorKind.custom => Icons.sensors,
};

const _accent = Color(0xFF087F8C);
const _warn = Color(0xFFC62828);

class SensorCard extends StatelessWidget {
  const SensorCard({super.key, required this.feed, required this.now, this.onRemove, this.onPlot});
  final SensorFeed feed;
  final DateTime now;
  final VoidCallback? onRemove;
  /// Opens a full-screen graph of a value (the headline, or a detail tapped).
  final void Function(PlotField field)? onPlot;

  PlotField? _headlineField(SensorSample? s) {
    if (s?.plot == null) return null;
    // Named like the card says it ("Nearest 0.49 m" -> "Nearest"), else by the sensor.
    final words = RegExp(r'^[^\d\-+]*').firstMatch(s!.headline)?.group(0)?.trim() ?? '';
    final label = feed.source.kind == SensorKind.custom ? (feed.source.fieldPath ?? feed.source.kind.label)
        : words.isNotEmpty && words.length <= 24 ? words : feed.source.kind.label;
    return sensorField(feed.source.kind, label, fieldPath: feed.source.fieldPath, headline: true, unit: s.plotUnit);
  }

  @override
  Widget build(BuildContext context) {
    final s = feed.latest;
    final last = feed.lastAt;
    final age = last == null ? null : now.difference(last);
    final rate = feed.rate(now);
    final stale = age != null && age > SensorPageState.staleAfter;
    final (dot, state) = last == null ? (Colors.blueGrey.shade300, context.strings.waitingData)
        // Custom topics are often published only on change, so silence there is not a fault.
        : stale && feed.source.kind == SensorKind.custom ? (Colors.blueGrey.shade400, context.strings.updatedAgo(age.inSeconds))
        : stale ? (Colors.orange, context.strings.noDataFor(age.inSeconds))
        : (const Color(0xFF2E7D32), '${rate.toStringAsFixed(rate < 10 ? 1 : 0)} Hz');
    final warning = s?.warning;
    return Container(
      key: Key('sensor-${feed.source.topic}'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: context.card, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: warning != null && !stale ? _warn.withValues(alpha: 0.5) : context.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_icon(feed.source.kind), color: _accent, size: 22),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(feed.source.kind.label, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text(feed.source.topic, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: context.muted, fontSize: 12)),
          ])),
        ]),
        const SizedBox(height: 6),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(state, key: Key('sensor-state-${feed.source.topic}'),
            style: TextStyle(color: context.muted, fontSize: 12)),
          if (onPlot != null && _headlineField(s) != null) IconButton(key: Key('sensor-plot-${feed.source.topic}'),
            tooltip: context.strings.graph, visualDensity: VisualDensity.compact, icon: const Icon(Icons.show_chart, size: 18),
            onPressed: () => onPlot!(_headlineField(s)!)),
          if (onRemove != null) IconButton(tooltip: context.strings.removeCustomSensor, onPressed: onRemove,
            visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18)),
        ]),
        const SizedBox(height: 12),
        Opacity(opacity: stale && feed.source.kind != SensorKind.custom ? 0.45 : 1, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s?.headline ?? '—', key: Key('sensor-value-${feed.source.topic}'),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, fontFeatures: [FontFeature.tabularFigures()])),
          if (warning != null) Padding(padding: const EdgeInsets.only(top: 4), child: Row(children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: _warn),
            const SizedBox(width: 4),
            Expanded(child: Text(warning, style: const TextStyle(color: _warn, fontWeight: FontWeight.w700, fontSize: 12))),
          ])),
          if (feed.error != null) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(feed.error!, style: const TextStyle(color: _warn, fontSize: 12))),
          const SizedBox(height: 10),
          if (s?.scan != null) SizedBox(height: 170, child: ScanView(points: s!.scan!))
          else if (feed.history.length > 1) InkWell(
            onTap: onPlot == null || _headlineField(s) == null ? null : () => onPlot!(_headlineField(s)!),
            child: SizedBox(height: 70, child: _Trend(feed: feed, unit: s?.plotUnit ?? '', now: now))),
          if (s != null && s.details.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10),
            child: Wrap(spacing: 16, runSpacing: 6, children: [
              for (final (label, value) in s.details) InkWell(
                key: Key('sensor-detail-$label'),
                borderRadius: BorderRadius.circular(6),
                // A number opens its graph (tap "Voltage 12.3 V" to see the voltage over time).
                onTap: onPlot == null || parseShownNumber(value).$1 == null ? null : () => onPlot!(sensorField(
                  feed.source.kind, label, fieldPath: feed.source.fieldPath, unit: parseShownNumber(value).$2)),
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: RichText(text: TextSpan(
                  style: TextStyle(fontSize: 12, color: context.muted),
                  children: [TextSpan(text: '$label  '), TextSpan(text: value,
                    style: TextStyle(color: context.ink, fontWeight: FontWeight.w700))])))),
            ])),
        ])),
      ]),
    );
  }
}

class _Trend extends StatelessWidget {
  const _Trend({required this.feed, required this.unit, required this.now});
  final SensorFeed feed;
  final String unit;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final spots = [for (final (t, v) in feed.history)
      FlSpot(-now.difference(t).inMilliseconds / 1000, v)];
    var lo = spots.map((p) => p.y).reduce(math.min), hi = spots.map((p) => p.y).reduce(math.max);
    // A minimum visible span per unit, so sensor noise is not blown up into a dramatic-looking chart.
    final minSpan = switch (unit) { '°/s' => 10.0, 'm/s' => 0.2, 'm' => 0.5, 'V' => 0.5, _ => 1.0 };
    if (hi - lo < minSpan) {
      final mid = (hi + lo) / 2;
      lo = mid - minSpan / 2; hi = mid + minSpan / 2;
    }
    final pad = (hi - lo) * 0.15;
    String fmt(double v) => v.abs() >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(v.abs() >= 10 ? 1 : 2);
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(child: LineChart(duration: Duration.zero, LineChartData(
        minX: -SensorPageState.window.inSeconds.toDouble(), maxX: 0, minY: lo - pad, maxY: hi + pad,
        titlesData: const FlTitlesData(show: false),
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        clipData: const FlClipData.all(),
        lineBarsData: [LineChartBarData(spots: spots, color: _accent, barWidth: 2, isCurved: false,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: _accent.withValues(alpha: 0.08)))],
      ))),
      const SizedBox(width: 8),
      Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text('${fmt(hi)} $unit', style: TextStyle(fontSize: 10, color: context.muted)),
        Text('30 s', style: TextStyle(fontSize: 10, color: context.muted)),
        Text('${fmt(lo)} $unit', style: TextStyle(fontSize: 10, color: context.muted)),
      ]),
    ]);
  }
}

/// Top-down LiDAR view: the sensor at the centre, forward (+x) up, range rings every metre.
class ScanView extends StatelessWidget {
  const ScanView({super.key, required this.points});
  final List<Offset> points;

  @override
  Widget build(BuildContext context) => ClipRRect(borderRadius: BorderRadius.circular(12),
    child: Container(color: const Color(0xFF13202C), child: CustomPaint(painter: _ScanPainter(points), size: Size.infinite)));
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.points);
  final List<Offset> points;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final far = points.isEmpty ? 1.0 : points.map((p) => p.distance).reduce(math.max);
    final reach = math.max(1.0, far.ceilToDouble());
    final scale = (math.min(size.width, size.height) / 2 - 6) / reach;
    final ring = Paint()..style = PaintingStyle.stroke..color = Colors.white12;
    for (var m = 1; m <= reach; m++) {
      canvas.drawCircle(c, m * scale, ring);
    }
    final dots = Paint()..color = const Color(0xFF4DD0E1)..strokeWidth = 2.5..strokeCap = StrokeCap.round;
    // Robot convention: x forward (screen up), y left (screen left).
    canvas.drawPoints(PointMode.points, [for (final p in points) c + Offset(-p.dy, -p.dx) * scale], dots);
    final robot = Path()..moveTo(c.dx, c.dy - 8)..lineTo(c.dx - 5, c.dy + 5)..lineTo(c.dx + 5, c.dy + 5)..close();
    canvas.drawPath(robot, Paint()..color = Colors.white);
    final label = TextPainter(text: TextSpan(text: '${reach.toStringAsFixed(0)} m',
      style: const TextStyle(color: Colors.white54, fontSize: 10)), textDirection: TextDirection.ltr)..layout();
    label.paint(canvas, Offset(size.width - label.width - 6, size.height - label.height - 4));
  }

  @override
  bool shouldRepaint(_ScanPainter old) => !identical(old.points, points);
}
