import 'app_language.dart';
import 'widgets/readable_width.dart';
import 'package:material_ui/material_ui.dart';

import 'app_theme.dart';
import 'robot_params.dart';
import 'robot_session.dart';

/// "Tune the robot": the settings people change most (speed, distance from obstacles, …) with plain
/// names and sliders, and every parameter of every node for the rest. Takes the place of
/// rqt_reconfigure / `ros2 param set` on a PC.
class TuneRobotPage extends StatefulWidget {
  const TuneRobotPage({super.key, required this.session});
  final RobotSession session;

  @override
  State<TuneRobotPage> createState() => _TuneRobotPageState();
}

class _TuneRobotPageState extends State<TuneRobotPage> {
  ParamClient? client;
  List<String> nodes = [];
  List<FoundSetting>? found;
  String? loadError;
  /// Programs on the robot that did not answer when settings were read.
  final silent = <String>{};
  /// New values (shown units) not applied yet, by setting key.
  final pending = <String, double>{};
  /// Problems from the last apply, by setting key.
  final problems = <String, String>{};
  bool applying = false;

  RobotSession get session => widget.session;

  /// Values when this robot was first tuned in this connection, so changes can be undone later.
  Map<String, double> get firstValues => session.tuningStart;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { found = null; loadError = null; });
    try {
      final caps = await session.capabilities();
      final c = client = ParamClient(session.ros, caps.rosVersion, namespace: session.namespace);
      nodes = [...caps.nodes]..sort();
      silent.clear();
      final f = await findCommonSettings(c, caps.nodes, silent: silent);
      for (final s in f) {
        final v = s.shown;
        if (v != null) firstValues.putIfAbsent(s.setting.key, () => v);
      }
      if (mounted) setState(() => found = f);
    } catch (e) {
      if (mounted) setState(() { found = const []; loadError = context.strings.settingsReadError('$e'); });
    }
  }

  Future<void> _apply() async {
    final c = client, f = found;
    if (c == null || f == null || pending.isEmpty) return;
    setState(() { applying = true; problems.clear(); });
    var ok = 0;
    for (final s in f) {
      final v = pending[s.setting.key];
      if (v == null) continue;
      final failed = await applySetting(c, s, v);
      if (failed.isEmpty) {
        ok++;
      } else {
        problems[s.setting.key] = failed.values.toSet().join(' ');
      }
    }
    if (!mounted) return;
    final kept = Map.of(pending)..removeWhere((k, _) => !problems.containsKey(k));
    pending..clear()..addAll(kept);
    silent.clear();
    final fresh = await findCommonSettings(c, nodes, silent: silent).catchError((_) => f);
    if (!mounted) return;
    setState(() { applying = false; found = fresh; });
    if (ok > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
          '${ok == 1 ? 'Setting' : '$ok settings'} changed on the robot. They last until it restarts.')));
    }
  }

  void _restoreFirst() {
    final f = found;
    if (f == null) return;
    setState(() {
      for (final s in f) {
        final first = firstValues[s.setting.key], now = s.shown;
        if (first != null && now != null && (first - now).abs() > 1e-9) pending[s.setting.key] = first;
      }
    });
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(length: 2, child: Scaffold(
    appBar: AppBar(
      title: Text(context.strings.tuneRobot),
      actions: [IconButton(tooltip: context.strings.readAgain, icon: const Icon(Icons.refresh), onPressed: applying ? null : _load)],
      bottom: TabBar(tabs: [Tab(text: context.strings.common), Tab(text: context.strings.allParameters)]),
    ),
    body: ReadableWidth(maxWidth: 760, child: TabBarView(children: [
      _common(),
      client == null ? const Center(child: CircularProgressIndicator())
          : _AllParams(client: client!, nodes: nodes),
    ])),
  ));

  Widget _common() {
    final f = found;
    if (f == null) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const CircularProgressIndicator(), const SizedBox(height: 12), Text(context.strings.readingSettings),
      ]));
    }
    final changedSinceConnect = f.any((s) {
      final first = firstValues[s.setting.key], now = s.shown;
      return first != null && now != null && (first - now).abs() > 1e-9;
    });
    return Column(children: [
      Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
        if (loadError != null) _note(loadError!, error: true),
        if (silent.isNotEmpty) _note('${silent.join(', ')} did not answer, so settings it holds are missing or '
            'only partly shown. Tap Read again (top right).', error: true),
        if (f.isEmpty && loadError == null) _empty()
        else ...[
          _note(context.strings.appliesUntilRestart),
          const SizedBox(height: 8),
          for (final s in f) _settingCard(s),
          if (changedSinceConnect && pending.isEmpty) Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            key: const Key('tune-restore'), onPressed: _restoreFirst, icon: const Icon(Icons.history, size: 18),
            label: Text(context.strings.backToFirst))),
        ],
      ])),
      if (pending.isNotEmpty) Material(elevation: 6, color: context.card, child: SafeArea(top: false, child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: [
          TextButton(key: const Key('tune-undo'), onPressed: applying ? null : () => setState(pending.clear),
            child: Text(context.strings.undo)),
          const Spacer(),
          FilledButton.icon(key: const Key('tune-apply'), onPressed: applying ? null : _apply,
            icon: applying
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.check, size: 18),
            label: Text(applying ? context.strings.applying : context.strings.applyChanges(pending.length))),
        ])))),
    ]);
  }

  Widget _note(String text, {bool error = false}) => Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(error ? Icons.error_outline : Icons.info_outline, size: 18,
        color: error ? Theme.of(context).colorScheme.error : context.muted),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 13,
        color: error ? Theme.of(context).colorScheme.error : context.muted))),
    ]));

  Widget _empty() => Padding(padding: const EdgeInsets.only(top: 48), child: Column(children: [
    Icon(Icons.tune, size: 48, color: context.muted),
    const SizedBox(height: 12),
    Text(context.strings.noCommonSettings, key: const Key('tune-empty'),
      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: context.ink)),
    const SizedBox(height: 6),
    Text(context.strings.noNavStack, textAlign: TextAlign.center,
      style: TextStyle(color: context.muted)),
  ]));

  Widget _settingCard(FoundSetting f) {
    final s = f.setting, cs = Theme.of(context).colorScheme;
    final now = f.shown ?? s.min;
    final value = pending[s.key] ?? now;
    final changed = pending.containsKey(s.key);
    final lo = now < s.min ? now : s.min, hi = now > s.max ? now : s.max;
    final divisions = ((hi - lo) / s.step).round();
    void setValue(double v) => setState(() {
      final snapped = (v / s.step).round() * s.step;
      final clamped = snapped.clamp(lo, hi).toDouble();
      // Back to the robot's value: nothing to apply (unless its parts disagree, then it evens them out).
      if ((clamped - now).abs() < s.step / 2 && !f.mixed) {
        pending.remove(s.key);
      } else {
        pending[s.key] = clamped;
      }
      problems.remove(s.key);
    });
    final problem = problems[s.key];
    return Card(key: Key('tune-${s.key}'), margin: const EdgeInsets.only(bottom: 10), elevation: 0,
      color: context.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: changed ? cs.primary : context.border, width: changed ? 1.5 : 1)),
      child: Padding(padding: const EdgeInsets.fromLTRB(16, 14, 8, 8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(settingLabel(context, s.key, s.label), style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: context.ink))),
            InkWell(borderRadius: BorderRadius.circular(8), onTap: () => _typeValue(f, value, setValue),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Text(s.format(value),
                key: Key('tune-${s.key}-value'),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: changed ? cs.primary : context.ink)))),
          ]),
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(settingHelp(context, s.key, s.help), style: TextStyle(fontSize: 13, color: context.muted))),
          Row(children: [
            IconButton(tooltip: context.strings.less, icon: const Icon(Icons.remove), onPressed: () => setValue(value - s.step)),
            Expanded(child: Slider(key: Key('tune-${s.key}-slider'), value: value.clamp(lo, hi).toDouble(),
              min: lo, max: hi, divisions: divisions > 0 ? divisions : null, label: s.format(value),
              onChanged: setValue)),
            IconButton(tooltip: context.strings.moreTimes, icon: const Icon(Icons.add), onPressed: () => setValue(value + s.step)),
          ]),
          if (f.mixed) Padding(padding: const EdgeInsets.only(left: 4, bottom: 4, right: 8), child: Text(
            context.strings.partsDisagree((f.allShown.toSet().toList()..sort()).map((v) => v.toStringAsFixed(s.decimals)).join(', '), s.unit),
            key: Key('tune-${s.key}-mixed'), style: const TextStyle(fontSize: 12, color: Color(0xFFB26A00)))),
          if (changed) Padding(padding: const EdgeInsets.only(left: 4, bottom: 4),
            child: Text(context.strings.nowOnRobot(s.format(now)), style: TextStyle(fontSize: 12, color: context.muted))),
          if (problem != null) Padding(padding: const EdgeInsets.only(left: 4, bottom: 4, right: 8),
            child: Text(context.strings.notChanged(problem), key: Key('tune-${s.key}-problem'),
              style: TextStyle(fontSize: 12, color: cs.error))),
        ])));
  }

  Future<void> _typeValue(FoundSetting f, double current, void Function(double) setValue) async {
    final s = f.setting;
    final text = await showDialog<String>(context: context, builder: (context) => _ValueDialog(
      title: settingLabel(context, s.key, s.label), initial: current.toStringAsFixed(s.decimals), suffix: s.unit, number: true));
    final v = double.tryParse(text ?? '');
    if (v != null) setValue(v);
  }
}

/// Every node and its parameters (ROS 2), or the whole parameter server (ROS 1), with search and editing.
class _AllParams extends StatefulWidget {
  const _AllParams({required this.client, required this.nodes});
  final ParamClient client;
  final List<String> nodes;

  @override
  State<_AllParams> createState() => _AllParamsState();
}

class _AllParamsState extends State<_AllParams> {
  String query = '';
  List<String>? ros1Names;

  @override
  void initState() {
    super.initState();
    if (widget.client.ros1) {
      widget.client.names('').then((n) { if (mounted) setState(() => ros1Names = n); },
          onError: (_) { if (mounted) setState(() => ros1Names = const []); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ros1 = widget.client.ros1;
    final all = ros1 ? (ros1Names ?? const <String>[]) : widget.nodes;
    final q = query.toLowerCase();
    final shown = [for (final n in all) if (q.isEmpty || n.toLowerCase().contains(q)) n];
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: TextField(key: const Key('params-search'),
        decoration: InputDecoration(prefixIcon: const Icon(Icons.search),
          hintText: ros1 ? context.strings.searchParameters : context.strings.searchNodes),
        onChanged: (v) => setState(() => query = v.trim()))),
      Expanded(child: ros1 && ros1Names == null ? const Center(child: CircularProgressIndicator())
          : shown.isEmpty ? Center(child: Text(context.strings.nothingFound, style: TextStyle(color: context.muted)))
          : ListView.builder(itemCount: shown.length, itemBuilder: (context, i) {
              final n = shown[i];
              return ListTile(title: Text(n), dense: ros1,
                leading: Icon(ros1 ? Icons.settings_outlined : Icons.memory, color: context.muted),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => ros1 ? _editRos1(n)
                    : Navigator.push(context, MaterialPageRoute(builder: (_) => NodeParamsPage(client: widget.client, node: n))));
            })),
    ]);
  }

  Future<void> _editRos1(String name) async {
    final v = (await widget.client.get('', [name]))[name];
    if (v == null || !mounted) return;
    await editParam(context, widget.client, '', name, v);
  }
}

/// One node's parameters, with their values; tap one to change it.
class NodeParamsPage extends StatefulWidget {
  const NodeParamsPage({super.key, required this.client, required this.node});
  final ParamClient client;
  final String node;

  @override
  State<NodeParamsPage> createState() => _NodeParamsPageState();
}

class _NodeParamsPageState extends State<NodeParamsPage> {
  Map<String, ParamValue>? values;
  String? error;
  String query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final names = await widget.client.names(widget.node);
      final v = await widget.client.get(widget.node, names);
      if (mounted) setState(() => values = v);
    } catch (e) {
      if (mounted) setState(() { values = const {}; error = context.strings.nodeNoAnswer('$e'); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final v = values, q = query.toLowerCase();
    final names = v == null ? const <String>[] : [for (final n in v.keys) if (q.isEmpty || n.toLowerCase().contains(q)) n];
    return Scaffold(
      appBar: AppBar(title: Text(widget.node)),
      body: ReadableWidth(maxWidth: 760, child: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 4), child: TextField(key: const Key('node-params-search'),
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: context.strings.searchParameters),
          onChanged: (t) => setState(() => query = t.trim()))),
        if (error != null) Padding(padding: const EdgeInsets.all(16),
          child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
        Expanded(child: v == null ? const Center(child: CircularProgressIndicator()) : ListView.builder(
          itemCount: names.length,
          itemBuilder: (context, i) {
            final n = names[i], p = v[n]!;
            return ListTile(title: Text(n, style: const TextStyle(fontSize: 14)),
              subtitle: Text(p.display(), maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontFamily: 'monospace', fontSize: 13, color: context.ink)),
              trailing: Text(p.typeName, style: TextStyle(fontSize: 11, color: context.muted)),
              onTap: () async {
                final changed = await editParam(context, widget.client, widget.node, n, p);
                if (changed != null && mounted) setState(() => values = {...v, n: changed});
              });
          })),
      ])),
    );
  }
}

/// Edits one parameter by its type; returns the new value once the robot accepted it.
Future<ParamValue?> editParam(BuildContext context, ParamClient client, String node, String name, ParamValue v) async {
  if (!v.isSet || v.type == ParamValue.byteArray) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.paramFixed)));
    return null;
  }
  ParamValue? next;
  if (v.type == ParamValue.boolean) {
    final b = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: Text(name), content: Text(context.strings.nowValue('${v.value}')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, !(v.value as bool)),
          child: Text(context.strings.setTo('${!(v.value as bool)}'))),
      ]));
    if (b != null) next = ParamValue(v.type, b);
  } else {
    final initial = v.isArray ? (v.value as List).join(', ') : '${v.value}';
    final text = await showDialog<String>(context: context, builder: (_) => _ValueDialog(
      title: name, initial: initial, number: v.isNumber,
      hint: v.isArray ? context.strings.commaValues : null));
    if (text == null) return null;
    next = _parse(v, text);
    if (next == null) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('"$text" is not a ${v.typeName}.')));
      }
      return null;
    }
  }
  if (next == null) return null;
  try {
    final failed = await client.set(node, {name: next});
    if (!context.mounted) return null;
    final reason = failed[name];
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(
        reason == null ? context.strings.paramChanged(name) : context.strings.notChanged(reason))));
    return reason == null ? next : null;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.notChanged('$e'))));
    }
    return null;
  }
}

ParamValue? _parse(ParamValue v, String text) {
  final t = text.trim();
  List<String> parts() => t.isEmpty ? const [] : t.split(',').map((e) => e.trim()).toList();
  switch (v.type) {
    case ParamValue.integer:
      final n = int.tryParse(t);
      return n == null ? null : ParamValue(v.type, n);
    case ParamValue.double_:
      final n = double.tryParse(t);
      return n == null ? null : ParamValue(v.type, n);
    case ParamValue.string:
      return ParamValue(v.type, text);
    case ParamValue.integerArray:
      final l = parts().map(int.tryParse).toList();
      return l.contains(null) ? null : ParamValue(v.type, l.cast<int>());
    case ParamValue.doubleArray:
      final l = parts().map(double.tryParse).toList();
      return l.contains(null) ? null : ParamValue(v.type, l.cast<double>());
    case ParamValue.boolArray:
      final l = parts().map((e) => e == 'true' ? true : e == 'false' ? false : null).toList();
      return l.contains(null) ? null : ParamValue(v.type, l.cast<bool>());
    case ParamValue.stringArray:
      return ParamValue(v.type, parts());
  }
  return null;
}

class _ValueDialog extends StatefulWidget {
  const _ValueDialog({required this.title, required this.initial, this.number = false, this.suffix, this.hint});
  final String title, initial;
  final bool number;
  final String? suffix, hint;

  @override
  State<_ValueDialog> createState() => _ValueDialogState();
}

class _ValueDialogState extends State<_ValueDialog> {
  late final controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(key: const Key('param-value'), controller: controller, autofocus: true,
      keyboardType: widget.number ? const TextInputType.numberWithOptions(decimal: true, signed: true) : TextInputType.text,
      decoration: InputDecoration(suffixText: widget.suffix, helperText: widget.hint),
      onSubmitted: (t) => Navigator.pop(context, t)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('param-value-ok'), onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('OK')),
    ],
  );
}

/// A common setting's name and help in the app's language (the setting list itself stays in English).
String settingLabel(BuildContext context, String key, String fallback) {
  final s = context.strings;
  return switch (key) {
    'speed' => s.setSpeed, 'turn' => s.setTurn, 'clearance' => s.setClearance, 'radius' => s.setRadius,
    'arrive' => s.setArrive, 'heading' => s.setHeading, 'sight' => s.setSight, _ => fallback,
  };
}

String settingHelp(BuildContext context, String key, String fallback) {
  final s = context.strings;
  return switch (key) {
    'speed' => s.setSpeedHelp, 'turn' => s.setTurnHelp, 'clearance' => s.setClearanceHelp, 'radius' => s.setRadiusHelp,
    'arrive' => s.setArriveHelp, 'heading' => s.setHeadingHelp, 'sight' => s.setSightHelp, _ => fallback,
  };
}
