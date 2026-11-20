import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'agent/agent.dart';
import 'agent/learned_tools.dart';
import 'agent/learning.dart';
import 'agent/manifest.dart';
import 'memory.dart';
import 'robot_persona.dart';
import 'robot_session.dart';
import 'widgets/readable_width.dart';
import 'widgets/robot_intro.dart';

/// What the assistant remembers about this robot and its person, to read, change and forget.
/// Everything here stays on this phone.
class RobotMemoryPage extends StatefulWidget {
  const RobotMemoryPage({super.key, required this.session, this.person, this.others = const []});
  final RobotSession session;
  /// The other robots on this connection, which a learned tool can be shared with.
  final List<RobotSession> others;
  /// The person's memory ([Memory.user] in the app).
  final Memory? person;

  @override
  State<RobotMemoryPage> createState() => _RobotMemoryPageState();
}

class _RobotMemoryPageState extends State<RobotMemoryPage> {
  late final Memory _robot = widget.session.memory;
  late final Memory _person = widget.person ?? Memory.user;

  @override
  void initState() {
    super.initState();
    _robot.load();
    _person.load();
  }

  Future<void> _edit(String title, Memory memory, String key, {String hint = ''}) async {
    final value = await showDialog<String>(context: context, builder: (_) => _TextDialog(title: title, hint: hint,
        initial: memory.profile(key) ?? '', fieldKey: const Key('memory-edit-field'), saveKey: const Key('memory-edit-save')));
    if (value != null) await memory.setProfile(key, value);
  }

  Future<void> _addNote() async {
    final s = context.strings;
    final value = await showDialog<String>(context: context, builder: (_) => _TextDialog(
        title: s.memNoteTitle, hint: s.introNotesHint, action: s.add,
        fieldKey: const Key('memory-note-field'), saveKey: const Key('memory-note-save')));
    if (value != null) await _robot.add('note', value, pinned: true);
  }

  /// Gives [tool] to the other robots that can do all of its steps.
  Future<void> _share(LearnedTool tool) async {
    final targets = <String, (Memory, AgentManifest)>{};
    for (final other in widget.others) {
      try {
        await other.prepare();
        final agent = RobotAgent.forSession(other, _NoModel());
        targets[other.label] = (other.memory, agent.manifest());
        agent.dispose();
      } catch (e) {
        targets.remove(other.label);
      }
    }
    final result = await Learning.share(tool, targets);
    if (!mounted) return;
    final lines = [
      if (result.shared.isNotEmpty) context.strings.sharedWith(result.shared.join(', ')),
      for (final e in result.refused.entries) context.strings.notShared(e.key, e.value),
    ];
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(lines.isEmpty ? context.strings.noOtherRobot : lines.join(' '))));
  }

  /// `2026-11-18 09:12 "ask" -> result` as the request, then when and how it went.
  Widget _event(MemoryItem e) {
    final m = RegExp(r'^(\S+ \S+) "(.*?)" -> (.*)$').firstMatch(e.text);
    return ListTile(key: Key('memory-event-${e.id}'), dense: true,
        title: Text(m == null ? e.text : m[2]!),
        subtitle: m == null ? null : Text('${m[1]} · ${m[3]}', maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _robot.remove(e.id)));
  }

  Future<void> _forget() async {
    final yes = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text(context.strings.forgetAllQuestion(widget.session.label)),
      content: Text(context.strings.forgetAllDetail),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('memory-forget-confirm'), onPressed: () => Navigator.pop(c, true), child: Text(context.strings.forget)),
      ],
    ));
    if (yes == true) await _robot.clear();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      toolbarHeight: MediaQuery.sizeOf(context).width < 520 &&
          MediaQuery.textScalerOf(context).scale(22) > 31 ? 112 : null,
      title: Text(context.strings.namePersonality, maxLines: 2)),
    body: ReadableWidth(child: ListenableBuilder(listenable: Listenable.merge([_robot, _person]), builder: (context, _) {
      final theme = Theme.of(context);
      Widget fact(String label, Memory memory, String key, {String hint = ''}) => ListTile(
        key: Key('memory-$key'),
        title: Text(label),
        subtitle: Text(memory.profile(key) ?? context.strings.notSet, style: TextStyle(
            color: memory.profile(key) == null ? theme.colorScheme.onSurfaceVariant : null)),
        trailing: const Icon(Icons.edit_outlined),
        onTap: () => _edit(label, memory, key, hint: hint),
      );
      final notes = _robot.ofKind('note').toList().reversed.toList();
      final episodes = _robot.ofKind('episode').toList().reversed.toList();
      final tools = [for (final i in _robot.ofKind(LearnedTool.kind)) if (LearnedTool.fromJson(i.data) case final t?) (i, t)];
      final phrases = _person.ofKind(Learning.aliasKind).toList();
      return ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
        if ((_robot.lastError ?? _person.lastError) case final error?) Padding(key: const Key('memory-save-error'),
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(context.strings.memSaveError(error),
                style: TextStyle(color: theme.colorScheme.error))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 8), child: Text(context.strings.memIntro)),
        fact(context.strings.name, _robot, RobotPersona.nameKey, hint: context.strings.memNameHint),
        fact(context.strings.role, _robot, RobotPersona.roleKey, hint: context.strings.memRoleHint),
        fact(context.strings.tone, _robot, RobotPersona.toneKey, hint: context.strings.memToneHint),
        fact(context.strings.kind, _robot, RobotPersona.kindKey, hint: context.strings.memKindHint),
        fact(context.strings.callPerson, _person, RobotPersona.callPersonKey, hint: context.strings.introCallMeHint),
        const Divider(),
        ListTile(title: Text(context.strings.thingsToRemember, style: theme.textTheme.titleSmall),
            trailing: IconButton(key: const Key('memory-add-note'), tooltip: context.strings.add, icon: const Icon(Icons.add), onPressed: _addNote)),
        if (notes.isEmpty) ListTile(dense: true, title: Text(context.strings.nothingYet)),
        for (final n in notes) ListTile(
          key: Key('memory-note-${n.id}'),
          dense: true,
          leading: Icon(n.source == 'assistant' ? Icons.smart_toy_outlined : Icons.person_outline, size: 20),
          title: Text(n.text),
          trailing: IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _robot.remove(n.id)),
        ),
        const Divider(),
        ListTile(title: Text(context.strings.recentEvents, style: theme.textTheme.titleSmall),
            subtitle: Text(context.strings.memEventsHint),
            trailing: episodes.isEmpty ? null : TextButton(key: const Key('memory-clear-events'),
                onPressed: () async { for (final e in episodes) { await _robot.remove(e.id); } },
                child: Text(context.strings.clear))),
        if (episodes.isEmpty) ListTile(dense: true, title: Text(context.strings.nothingYet)),
        for (final e in episodes.take(30)) _event(e),
        const Divider(),
        ExpansionTile(key: const Key('memory-learned'), shape: const Border(),
          title: Text(context.strings.learnedCount(tools.length + phrases.length), style: theme.textTheme.titleSmall),
          subtitle: Text(context.strings.learnedHint),
          children: [
            if (tools.isEmpty && phrases.isEmpty) ListTile(dense: true, title: Text(context.strings.nothingYet)),
            for (final (item, t) in tools) ListTile(key: Key('memory-tool-${t.name}'), dense: true,
              leading: Icon(t.origin == 'habit' ? Icons.repeat : Icons.smart_toy_outlined, size: 20),
              title: Text(t.phrases.isEmpty ? t.name : t.phrases.map((p) => '"$p"').join(', ')),
              subtitle: Text(context.strings.toolSteps(t.steps.length, t.steps.map((s) => s.name).join(' → '))),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (widget.others.isNotEmpty) IconButton(key: Key('memory-share-${t.name}'), tooltip: context.strings.shareOthers,
                    icon: const Icon(Icons.share_outlined), onPressed: () => _share(t)),
                IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _robot.remove(item.id)),
              ])),
            for (final p in phrases) ListTile(key: Key('memory-phrase-${p.key}'), dense: true,
              leading: const Icon(Icons.translate, size: 20),
              title: Text(context.strings.phraseMeans(p.key ?? '', p.text)),
              subtitle: Text(context.strings.forAllRobots),
              trailing: IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _person.remove(p.id))),
          ]),
        const Divider(),
        ListTile(key: const Key('memory-talk-again'), leading: const Icon(Icons.waving_hand_outlined),
            title: Text(context.strings.talkAgain),
            onTap: () => RobotIntroSheet.open(context, widget.session)),
        ListTile(key: const Key('memory-forget'), leading: Icon(Icons.delete_forever_outlined, color: theme.colorScheme.error),
            title: Text(context.strings.forgetMemory, style: TextStyle(color: theme.colorScheme.error)), onTap: _forget),
      ]);
    })),
  );
}

/// One line of text to enter; owns its field (it lives through the closing animation).
class _TextDialog extends StatefulWidget {
  const _TextDialog({required this.title, required this.fieldKey, required this.saveKey, this.hint = '',
      this.initial = '', this.action});
  final String title, hint, initial;
  final String? action;
  final Key fieldKey, saveKey;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(key: widget.fieldKey, controller: _text, autofocus: true,
        decoration: InputDecoration(hintText: widget.hint), onSubmitted: (v) => Navigator.pop(context, v)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: widget.saveKey, onPressed: () => Navigator.pop(context, _text.text), child: Text(widget.action ?? context.strings.save)),
    ],
  );
}

/// No model: a robot's tool list is all that is needed to see what a shared tool would do there.
class _NoModel extends AgentBackend {
  @override
  String get name => 'none';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => const AgentPlan();
}
