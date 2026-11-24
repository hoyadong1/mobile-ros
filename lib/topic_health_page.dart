import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_language.dart';
import 'app_theme.dart';
import 'diagnostics.dart';
import 'diagnostics_page.dart';
import 'explorer_page.dart' show isHeavyType;
import 'message_schema.dart' show normalizeType;
import 'ros_connection.dart';
import 'topic_health.dart';
import 'widgets/throttled_rebuild.dart';

/// A few of the robot's topics at a glance: rate now and usually, time since the last message, and
/// what looks wrong (overdue, slow, values frozen, timestamps stuck). For standing next to a robot and
/// asking "is the lidar still alive?".
class TopicHealthPage extends StatefulWidget {
  const TopicHealthPage({super.key, required this.connection, required this.topicTypes, this.remote = false,
    this.clock = DateTime.now});

  final RosConnection connection;
  final Map<String, String> topicTypes;
  /// Over the remote relay messages are throttled: only "still arriving" can be judged.
  final bool remote;
  final DateTime Function() clock;

  static const _prefsKey = 'topic_health_topics';

  @override
  State<TopicHealthPage> createState() => TopicHealthPageState();
}

class TopicHealthPageState extends State<TopicHealthPage> with ThrottledRebuild {
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 500);

  final health = <String, TopicHealth>{};
  StreamSubscription? _sub;
  Timer? _ticker;
  bool _loaded = false;
  static int _instances = 0;
  final _id = 'health-${_instances++}';

  @override
  void initState() {
    super.initState();
    _sub = widget.connection.messages.listen((e) {
      if (e['op'] != 'publish') return;
      final h = health[e['topic']];
      if (h == null) return;
      h.onMessage(e['msg'], widget.clock());
      rebuildSoon();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = widget.clock();
      for (final h in health.values) {
        h.tick(now);
      }
      if (mounted) setState(() {});
    });
    _start();
  }

  Future<void> _start() async {
    List<String>? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getStringList(TopicHealthPage._prefsKey);
    } catch (_) {}
    final present = saved?.where(widget.topicTypes.containsKey).toList();
    final topics = present != null && present.isNotEmpty ? present : pickHealthTopics(widget.topicTypes);
    if (!mounted) return;
    setState(() => _loaded = true);
    _watch(topics);
  }

  void _watch(List<String> topics) {
    for (final t in health.keys.where((t) => !topics.contains(t)).toList()) {
      _unsubscribe(t);
      health.remove(t);
    }
    for (final t in topics) {
      if (health.containsKey(t)) continue;
      final type = widget.topicTypes[t] ?? '';
      final heavy = isHeavyType(type);
      health[t] = TopicHealth(t, type, limited: heavy || widget.remote);
      try {
        // Light topics unthrottled so the rate is the robot's; large ones (camera, clouds) once a second.
        widget.connection.send({'op': 'subscribe', 'id': '$_id-$t', 'topic': t,
          'throttle_rate': heavy ? 1000 : 0, 'queue_length': 1});
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  void _unsubscribe(String topic) {
    try { widget.connection.send({'op': 'unsubscribe', 'id': '$_id-$topic', 'topic': topic}); } catch (_) {}
  }

  Future<void> _choose() async {
    final picked = await showModalBottomSheet<List<String>>(context: context, isScrollControlled: true,
      showDragHandle: true, builder: (_) => _TopicPicker(topicTypes: widget.topicTypes, selected: health.keys.toSet()));
    if (picked == null || !mounted) return;
    _watch(picked);
    try {
      await (await SharedPreferences.getInstance()).setStringList(TopicHealthPage._prefsKey, picked);
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    for (final t in health.keys) {
      _unsubscribe(t);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final now = widget.clock();
    final items = health.values.toList();
    final bad = items.where((h) => _isProblem(h.condition(now))).length;
    final waiting = items.where((h) => h.condition(now) == TopicCondition.waiting).length;
    return Scaffold(
      appBar: AppBar(title: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
        child: Text(s.topicHealth)), actions: [
        IconButton(key: const Key('health-choose'), tooltip: s.chooseTopics, icon: const Icon(Icons.checklist),
          onPressed: _loaded ? _choose : null),
      ]),
      body: !_loaded ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (pickDiagnosticsTopic(widget.topicTypes) case final diag?) ...[
            Card(margin: EdgeInsets.zero, child: ListTile(key: const Key('health-diagnostics'),
              leading: const Icon(Icons.health_and_safety_outlined, color: Color(0xFF087F8C)),
              title: Text(s.robotDiagnostics, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(s.robotDiagnosticsHint), trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(context, MaterialPageRoute<void>(
                builder: (_) => DiagnosticsPage(connection: widget.connection, topic: diag))))),
            const SizedBox(height: 12),
          ],
          if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 32), child: Column(children: [
            Text(s.noHealthTopics, textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _choose, child: Text(s.chooseTopics)),
          ]))
          else ...[
            Card(key: const Key('health-summary'), margin: EdgeInsets.zero,
              color: bad > 0 ? context.cs.errorContainer : null,
              child: ListTile(
                leading: Icon(bad > 0 ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                  color: bad > 0 ? context.cs.onErrorContainer : const Color(0xFF00897B)),
                title: Text(bad > 0 ? s.topicsNeedAttention(bad)
                    : waiting == items.length ? s.waitingMessages : s.topicsLookFine(items.length - waiting),
                  style: TextStyle(fontWeight: FontWeight.w700, color: bad > 0 ? context.cs.onErrorContainer : null)),
                subtitle: widget.remote ? Text(s.healthRemoteNote) : null)),
            const SizedBox(height: 12),
            for (final h in items) _tile(context, h, now),
            const SizedBox(height: 8),
            Text(s.topicHealthHint, style: TextStyle(fontSize: 12, color: context.muted)),
          ],
        ]),
    );
  }

  static bool _isProblem(TopicCondition c) => c != TopicCondition.ok && c != TopicCondition.waiting;

  Widget _tile(BuildContext context, TopicHealth h, DateTime now) {
    final s = context.strings;
    final c = h.condition(now);
    final color = switch (c) {
      TopicCondition.ok => const Color(0xFF00897B),
      TopicCondition.waiting => context.muted,
      TopicCondition.slow || TopicCondition.badStamp => const Color(0xFFB26A00),
      TopicCondition.stale || TopicCondition.frozen => const Color(0xFFB3261E),
    };
    final label = switch (c) {
      TopicCondition.ok => s.healthOk,
      TopicCondition.waiting => s.healthWaiting,
      TopicCondition.slow => s.healthSlow,
      TopicCondition.stale => s.healthStale,
      TopicCondition.frozen => s.healthFrozen,
      TopicCondition.badStamp => s.healthBadStamp,
    };
    final since = h.sinceLast(now);
    final rate = h.rate(now);
    final usual = h.usualRate;
    String hz(double r) => r.toStringAsFixed(r < 10 ? 1 : 0);
    final facts = <String>[
      if (h.limited) s.healthStillArriving
      else if (h.received > 0) usual == null ? '${hz(rate)} Hz' : s.healthRateUsual(hz(rate), hz(usual)),
      if (since != null) s.healthLastAgo(_ago(since)),
    ];
    final why = switch (c) {
      TopicCondition.stale => s.healthStaleWhy,
      TopicCondition.frozen => s.healthFrozenWhy(_ago(h.frozenFor(now)!)),
      TopicCondition.badStamp => h.stampWentBack ? s.healthStampBackWhy : s.healthStampSameWhy,
      TopicCondition.slow => s.healthSlowWhy,
      _ => null,
    };
    return Card(key: Key('health-${h.topic}'), margin: const EdgeInsets.only(bottom: 8),
      child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 12), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.circle, size: 12, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(h.topic, style: const TextStyle(fontWeight: FontWeight.w700),
              overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 8),
            Text(label, key: Key('health-state-${h.topic}'),
              style: TextStyle(color: color, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 4),
          Text(normalizeType(h.type), style: TextStyle(fontSize: 12, color: context.muted)),
          if (facts.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(facts.join(' · '))),
          if (why != null) Padding(padding: const EdgeInsets.only(top: 4),
            child: Text(why, style: TextStyle(fontSize: 13, color: color))),
        ])));
  }

  String _ago(Duration d) {
    final s = context.strings;
    if (d.inSeconds < 1) return s.healthUnderSecond;
    if (d.inSeconds < 60) return s.healthSeconds(d.inSeconds);
    return s.healthMinutes(d.inMinutes);
  }
}

class _TopicPicker extends StatefulWidget {
  const _TopicPicker({required this.topicTypes, required this.selected});

  final Map<String, String> topicTypes;
  final Set<String> selected;

  @override
  State<_TopicPicker> createState() => _TopicPickerState();
}

class _TopicPickerState extends State<_TopicPicker> {
  late final selected = {...widget.selected};
  String query = '';
  static const max = 15;

  @override
  Widget build(BuildContext context) {
    final s = context.strings;
    final q = query.toLowerCase();
    final topics = widget.topicTypes.keys.where((t) => q.isEmpty || t.toLowerCase().contains(q)
        || widget.topicTypes[t]!.toLowerCase().contains(q)).toList()..sort();
    return SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * 0.75, child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Row(children: [
        Expanded(child: Text(s.chooseTopicsCount(selected.length, max),
          style: const TextStyle(fontWeight: FontWeight.w700))),
        FilledButton(key: const Key('health-choose-done'),
          onPressed: () => Navigator.pop(context, [
            for (final t in widget.topicTypes.keys.toList()..sort()) if (selected.contains(t)) t]),
          child: Text(s.done)),
      ])),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
        decoration: InputDecoration(isDense: true, prefixIcon: const Icon(Icons.search), hintText: s.searchNamesTypes),
        onChanged: (v) => setState(() => query = v.trim()))),
      Expanded(child: ListView(children: [
        for (final t in topics) CheckboxListTile(key: Key('health-pick-$t'), dense: true,
          value: selected.contains(t), title: Text(t), subtitle: Text(normalizeType(widget.topicTypes[t]!)),
          onChanged: !selected.contains(t) && selected.length >= max ? null
              : (v) => setState(() => v == true ? selected.add(t) : selected.remove(t))),
      ])),
    ])));
  }
}
