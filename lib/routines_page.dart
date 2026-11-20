import 'widgets/readable_width.dart';
import 'tool_tabs.dart';
import 'app_language.dart';
import 'package:material_ui/material_ui.dart';
import 'agent/skill_labels.dart';
import 'agent/agent.dart';
import 'agent/manifest.dart';
import 'agent/skill.dart';
import 'agent/validator.dart';
import 'routines.dart';
import 'robot_widget.dart';

/// A backend for an agent that only runs saved routines: there is no model to plan with.
class NoPlanner extends AgentBackend {
  @override
  String get name => 'routine';
  @override
  Future<AgentPlan> plan(AgentRequest request) async =>
      const AgentPlan(reply: 'Use the AI assistant to give instructions in words.');
}

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String scheduleText(RoutineSchedule s) {
  final days = s.weekdays.length == 7
      ? 'Every day'
      : s.weekdays.length == 5 && s.weekdays.containsAll({1, 2, 3, 4, 5}) && !s.weekdays.contains(6)
          ? 'Weekdays'
          : (s.weekdays.toList()..sort()).map((d) => _weekdayNames[d - 1]).join(' ');
  return '$days ${s.label}${s.enabled ? '' : ' (off)'}';
}

/// Saved routines: run one, build or change one, and set when it runs by itself. Every step still goes
/// through the agent's validator when it runs.
class RoutinesPage extends StatefulWidget {
  const RoutinesPage({super.key, required this.book, required this.agent, this.prepare});

  final RoutineBook book;
  /// Runs routines (validated, logged with the assistant's history, stoppable).
  final RobotAgent agent;
  final Future<void> Function()? prepare;

  @override
  State<RoutinesPage> createState() => _RoutinesPageState();
}

class _RoutinesPageState extends State<RoutinesPage> {
  @override
  void initState() {
    super.initState();
    widget.book.addListener(_changed);
    widget.agent.addListener(_changed);
    if (!widget.book.loaded) widget.book.load();
    widget.prepare?.call().then((_) => _changed(), onError: (_) {});
  }

  @override
  void dispose() {
    widget.book.removeListener(_changed);
    widget.agent.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _run(Routine r) async {
    RobotWidget.rememberRoutine(r.id); // the home screen widget's Run button starts this one
    final run = await widget.agent.runRoutine(r);
    if (!mounted) return;
    final message = run.error ?? run.results.lastOrNull?.message ?? 'Done.';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _progressCard(RoutineProgress p) {
    final cs = Theme.of(context).colorScheme;
    final waiting = p.waitingUntil;
    final detail = waiting != null
        ? context.strings.nextRound(secondsLeft(waiting))
        : p.steps == 0 ? context.strings.starting : context.strings.stepOf(p.step, p.steps, p.doing);
    return Card(key: const Key('routine-progress'), color: cs.primaryContainer,
      child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.strings.runningNamed(p.routine), style: TextStyle(fontWeight: FontWeight.w800, color: cs.onPrimaryContainer)),
          const SizedBox(height: 2),
          Text('${p.roundText(context.strings)} · $detail', style: TextStyle(color: cs.onPrimaryContainer)),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: p.steps == 0 ? null : p.step / p.steps),
        ])),
        const SizedBox(width: 12),
        FilledButton.icon(key: const Key('routine-progress-stop'), onPressed: widget.agent.stop,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E), foregroundColor: Colors.white),
          icon: const Icon(Icons.stop), label: Text(context.strings.stopRoutine)),
      ])));
  }

  Future<void> _edit([Routine? r]) async {
    await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RoutineEditorPage(
        book: widget.book, manifest: widget.agent.manifest(),
        routine: r ?? Routine(id: RoutineBook.newId(), name: '', steps: const []))));
  }

  Future<void> _delete(Routine r) async {
    final users = widget.book.usersOf(r.id);
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(context.strings.deleteQuestion(r.name)),
      content: users.isEmpty ? null : Text(context.strings.usedBy(users.map((u) => u.name).join(', '))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(context.strings.delete)),
      ]));
    if (ok == true) await widget.book.remove(r.id);
  }

  @override
  Widget build(BuildContext context) {
    final routines = widget.book.routines;
    final busy = widget.agent.busy;
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        title: Text(context.strings.routines, style: const TextStyle(fontWeight: FontWeight.w800)), actions: [
        IconButton(key: const Key('routine-stop'), tooltip: context.strings.stopRoutine, icon: const Icon(Icons.stop_circle_outlined),
            color: const Color(0xFFB3261E), onPressed: widget.agent.stop),
      ]),
      floatingActionButton: FloatingActionButton.extended(key: const Key('routine-new'), onPressed: () => _edit(),
          icon: const Icon(Icons.add), label: Text(context.strings.newRoutine)),
      body: ReadableWidth(maxWidth: 720, child: SafeArea(child: routines.isEmpty
          ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.playlist_play, size: 48, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(context.strings.noRoutines, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              const SizedBox(height: 6),
              Text(context.strings.routineHint,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            ])))
          : ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 96), children: [
              if (widget.agent.progress case final p?) _progressCard(p)
              else if (busy) const LinearProgressIndicator(minHeight: 2),
              for (final r in routines) Card(child: ListTile(
                key: Key('routine-${r.name}'),
                title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text([
                  '${r.steps.length} step${r.steps.length == 1 ? '' : 's'}',
                  if (r.repeat != 1) repeatText(r),
                  ...r.schedules.map(scheduleText),
                ].join(' · ')),
                onTap: () => _edit(r),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(key: Key('routine-run-${r.name}'), tooltip: context.strings.runRoutine, icon: const Icon(Icons.play_arrow),
                      onPressed: busy ? null : () => _run(r)),
                  IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _delete(r)),
                ]),
              )),
            ]))),
    );
  }
}

/// Builds or changes one routine: its name, its steps (skills with their arguments, or other routines),
/// and its schedules.
class RoutineEditorPage extends StatefulWidget {
  const RoutineEditorPage({super.key, required this.book, required this.manifest, required this.routine});

  final RoutineBook book;
  final AgentManifest manifest;
  final Routine routine;

  @override
  State<RoutineEditorPage> createState() => _RoutineEditorPageState();
}

class _RoutineEditorPageState extends State<RoutineEditorPage> {
  late final _name = TextEditingController(text: widget.routine.name);
  late List<RoutineStep> _steps = [...widget.routine.steps];
  late List<RoutineSchedule> _schedules = [...widget.routine.schedules];
  late int _repeat = widget.routine.repeat;
  late int _pause = widget.routine.pauseSeconds;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String _stepText(RoutineStep s) {
    if (s.call != null) return describeCall(s.call!);
    return '▶ ${widget.book.byId(s.routineId!)?.name ?? '(deleted routine)'}';
  }

  Future<void> _save() async {
    try {
      await widget.book.save(widget.routine.copyWith(name: _name.text, steps: _steps, schedules: _schedules,
          repeat: _repeat, pauseSeconds: _repeat == 1 ? 0 : _pause));
      if (mounted) Navigator.pop(context);
    } on RoutineError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _addSkill() async {
    final call = await showDialog<SkillCall>(context: context, builder: (_) => _SkillStepDialog(manifest: widget.manifest));
    if (call != null) setState(() => _steps = [..._steps, RoutineStep.call(call)]);
  }

  Future<void> _addRoutine() async {
    final others = [for (final r in widget.book.routines) if (r.id != widget.routine.id) r];
    final picked = await showDialog<Routine>(context: context, builder: (c) => SimpleDialog(
      title: Text(context.strings.addRoutineStep),
      children: [
        if (others.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(context.strings.noOtherRoutines)),
        for (final r in others) SimpleDialogOption(onPressed: () => Navigator.pop(c, r), child: Text(r.name)),
      ]));
    if (picked != null) setState(() => _steps = [..._steps, RoutineStep.routine(picked.id)]);
  }

  Future<void> _addSchedule() async {
    final time = await showTimePicker(context: context, initialTime: const TimeOfDay(hour: 9, minute: 0));
    if (time != null) {
      setState(() => _schedules = [..._schedules, RoutineSchedule(hour: time.hour, minute: time.minute)]);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.routine.name.isEmpty ? 'New routine' : 'Edit routine'), actions: [
      TextButton(key: const Key('routine-save'), onPressed: _save, child: Text(context.strings.save)),
    ]),
    body: ReadableWidth(maxWidth: 720, child: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
      TextField(key: const Key('routine-name'), controller: _name,
          decoration: InputDecoration(labelText: context.strings.name, border: const OutlineInputBorder())),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
      const SizedBox(height: 20),
      Text(context.strings.steps, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      ReorderableListView(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), buildDefaultDragHandles: true,
        onReorderItem: (from, to) => setState(() {
          final list = [..._steps];
          list.insert(to, list.removeAt(from));
          _steps = list;
        }),
        children: [
          for (final (i, s) in _steps.indexed) ListTile(key: ValueKey('step-$i-${_stepText(s)}'),
            leading: Text('${i + 1}'),
            title: Text(_stepText(s)),
            trailing: IconButton(icon: const Icon(Icons.close), tooltip: context.strings.remove,
                onPressed: () => setState(() => _steps = [..._steps]..removeAt(i)))),
        ]),
      if (_steps.isEmpty)
        Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(
          context.strings.noSteps,
          style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant))),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(key: const Key('routine-add-step'), onPressed: _addSkill,
            icon: const Icon(Icons.add), label: Text(context.strings.addStep)),
        OutlinedButton.icon(onPressed: _addRoutine, icon: const Icon(Icons.playlist_add), label: Text(context.strings.addRoutine)),
      ]),
      const SizedBox(height: 24),
      Text(context.strings.repeat, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 8),
      SegmentedButton<int>(key: const Key('routine-repeat'), showSelectedIcon: false,
        segments: [
          ButtonSegment(value: 1, label: Text(context.strings.once)),
          ButtonSegment(value: 2, label: Text(context.strings.times)),
          ButtonSegment(value: 0, label: Text(context.strings.untilStopped)),
        ],
        selected: {_repeat == 0 ? 0 : _repeat == 1 ? 1 : 2},
        onSelectionChanged: (v) => setState(() => _repeat = v.first == 2 ? (_repeat > 1 ? _repeat : 3) : v.first)),
      if (_repeat > 1) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [
        IconButton.outlined(key: const Key('routine-repeat-less'), tooltip: context.strings.fewer, icon: const Icon(Icons.remove),
          onPressed: _repeat > 2 ? () => setState(() => _repeat--) : null),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(context.strings.timesCount(_repeat), key: const Key('routine-repeat-count'),
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
        IconButton.outlined(key: const Key('routine-repeat-more'), tooltip: context.strings.moreTimes, icon: const Icon(Icons.add),
          onPressed: _repeat < Routine.maxRepeat ? () => setState(() => _repeat++) : null),
      ])),
      if (_repeat != 1) Padding(padding: const EdgeInsets.only(top: 8), child: Row(children: [
        Text(context.strings.waitBetween),
        const SizedBox(width: 12),
        DropdownButton<int>(key: const Key('routine-pause'), value: _pauses.contains(_pause) ? _pause : 0,
          items: [for (final p in _pauses) DropdownMenuItem(value: p, child: Text(_pauseText(p)))],
          onChanged: (v) => setState(() => _pause = v ?? 0)),
      ])),
      if (_repeat != 1) Padding(padding: const EdgeInsets.only(top: 4), child: Text(
        context.strings.keepsGoing,
        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant))),
      const SizedBox(height: 24),
      Text(context.strings.schedule, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
      for (final (i, s) in _schedules.indexed) Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(
        crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(s.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const Spacer(),
            Switch(value: s.enabled, onChanged: (v) => setState(() => _schedules[i] = s.copyWith(enabled: v))),
            IconButton(icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() => _schedules = [..._schedules]..removeAt(i))),
          ]),
          Wrap(spacing: 4, children: [
            for (var d = 1; d <= 7; d++) FilterChip(label: Text(_weekdayNames[d - 1]), selected: s.weekdays.contains(d),
                onSelected: (on) => setState(() => _schedules[i] =
                    s.copyWith(weekdays: on ? {...s.weekdays, d} : ({...s.weekdays}..remove(d))))),
          ]),
        ]))),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(key: const Key('routine-add-schedule'),
          onPressed: _addSchedule, icon: const Icon(Icons.schedule), label: Text(context.strings.addTime))),
    ]))),
  );
}

const _pauses = [0, 10, 30, 60, 300, 600, 1800, 3600];
String _pauseText(int s) => s == 0 ? 'None' : s < 60 ? '$s s' : '${s ~/ 60} min';

/// Picks one skill and fills in its arguments; the result is checked by the validator before it is
/// added, so a routine never holds a step that could not run.
class _SkillStepDialog extends StatefulWidget {
  const _SkillStepDialog({required this.manifest});
  final AgentManifest manifest;

  @override
  State<_SkillStepDialog> createState() => _SkillStepDialogState();
}

class _SkillStepDialogState extends State<_SkillStepDialog> {
  static const _hidden = {'save_routine', 'run_routine', 'get_status', 'stop'};
  late final skills = inEverydayOrder([for (final s in widget.manifest.skills) if (!_hidden.contains(s.name)) s]);
  late Skill? _skill = skills.firstOrNull;
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  String? _error;

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _add() {
    final s = _skill;
    if (s == null) return;
    final args = <String, Object?>{
      for (final p in s.params)
        if (p.values != null) ...{if (_choice[p.name] != null) p.name: _choice[p.name]}
        else if ((_text[p.name]?.text.trim() ?? '').isNotEmpty)
          p.name: p.type == ParamType.number ? double.tryParse(_text[p.name]!.text.trim()) ?? _text[p.name]!.text : _text[p.name]!.text.trim(),
    };
    final verdict = validateCall(SkillCall(s.name, args), widget.manifest);
    if (!verdict.ok) {
      setState(() => _error = verdict.rejection);
      return;
    }
    Navigator.pop(context, SkillCall(s.name, verdict.call!.args));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.addStep),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<Skill>(key: const Key('routine-skill'), initialValue: _skill,
        isExpanded: true, itemHeight: null,
        decoration: InputDecoration(labelText: context.strings.whatRobotDoes),
        items: [for (final s in skills) DropdownMenuItem(value: s, child: Row(children: [
          Icon(skillLabel(s.name).icon, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(skillLabel(s.name).title)),
        ]))],
        onChanged: (s) => setState(() {
          _skill = s;
          _error = null;
        })),
      if (_skill != null) Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(skillLabel(_skill!.name).description, style: const TextStyle(fontSize: 12))),
      for (final p in _skill?.params ?? const <SkillParam>[])
        Padding(padding: const EdgeInsets.only(top: 12), child: p.values != null
          ? DropdownButtonFormField<String>(key: Key('routine-param-${p.name}'), initialValue: _choice[p.name],
              isExpanded: true, itemHeight: null,
              decoration: InputDecoration(labelText: paramLabel(p)),
              items: [for (final v in p.values!) DropdownMenuItem(value: v, child: Text(v))],
              onChanged: (v) => _choice[p.name] = v)
          : TextField(key: Key('routine-param-${p.name}'),
              controller: _text.putIfAbsent(p.name, TextEditingController.new),
              keyboardType: p.type == ParamType.number
                  ? const TextInputType.numberWithOptions(signed: true, decimal: true) : TextInputType.text,
              decoration: InputDecoration(labelText: paramLabel(p),
                  helperText: p.min != null && p.max != null ? '${p.min} .. ${p.max}' : null))),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('routine-step-add'), onPressed: _add, child: Text(context.strings.add)),
    ],
  );
}
