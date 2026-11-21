import '../app_language.dart';
import 'package:material_ui/material_ui.dart';

import '../memory.dart';
import '../robot_persona.dart';
import '../robot_profile.dart';
import '../robot_session.dart';
import '../robot_summary.dart';

/// On the robot home until the first meeting was had or put off: the robot offers to introduce itself.
class RobotIntroCard extends StatefulWidget {
  const RobotIntroCard({super.key, required this.session, this.recognisedAs});
  final RobotSession session;
  /// What the robot was recognised as ("TurtleBot3"), used until the person names it; without it the
  /// card falls back to the connection's name (an address).
  final String? recognisedAs;

  @override
  State<RobotIntroCard> createState() => _RobotIntroCardState();
}

class _RobotIntroCardState extends State<RobotIntroCard> {
  @override
  void initState() {
    super.initState();
    widget.session.memory.load();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.session.memory,
    builder: (context, _) {
      final memory = widget.session.memory;
      if (!memory.loaded || memory.profile(RobotPersona.introducedKey) != null) return const SizedBox.shrink();
      final theme = Theme.of(context);
      return Card(key: const Key('robot-intro-card'), margin: EdgeInsets.zero, child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.waving_hand_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(child: Text(context.strings.meetRobot(memory.profile(RobotPersona.nameKey) ?? widget.recognisedAs ?? widget.session.label), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
          ]),
          const SizedBox(height: 6),
          Text(context.strings.introHint),
          OverflowBar(alignment: MainAxisAlignment.end, overflowAlignment: OverflowBarAlignment.end, children: [
            TextButton(key: const Key('robot-intro-later'), onPressed: () => memory.setProfile(RobotPersona.introducedKey, 'later'),
                child: Text(context.strings.notNow)),
            FilledButton.tonal(key: const Key('robot-intro-start'), onPressed: () => RobotIntroSheet.open(context, widget.session),
                child: Text(context.strings.sayHello)),
          ]),
        ])));
    },
  );
}

/// The first meeting: the robot asks what it needs to know, one question at a time, and remembers each
/// answer as it is given (leaving halfway keeps what was said). Also opened later to change the answers.
class RobotIntroSheet extends StatefulWidget {
  const RobotIntroSheet({super.key, required this.session, this.person});
  final RobotSession session;
  /// The person's memory ([Memory.user] in the app).
  final Memory? person;

  static Future<void> open(BuildContext context, RobotSession session) => showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (_) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
          child: RobotIntroSheet(session: session)));

  @override
  State<RobotIntroSheet> createState() => _RobotIntroSheetState();
}

class _Step {
  const _Step(this.id, this.question, {this.choices = const [], this.hint = '', this.free = true});
  final String id;
  final String question;
  final List<String> choices;
  final String hint;
  /// Whether a typed answer is taken (otherwise only the choices).
  final bool free;
}

class _RobotIntroSheetState extends State<RobotIntroSheet> {
  late final Memory _robot = widget.session.memory;
  late final Memory _person = widget.person ?? Memory.user;
  final _said = <(bool, String)>[]; // (from the robot, text)
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<_Step> _steps = const [];
  int _at = 0;
  RobotSummary? _summary;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    await Future.wait([_robot.load(), _person.load()]);
    try {
      final s = widget.session;
      final profile = s.drive.profile ?? await ProfileStore.loadAt(s.storeAddress);
      _summary = RobotSummary.from(await s.capabilities(), profile: profile);
    } catch (_) {}
    if (!mounted) return;
    // "Mobile robot (turns in place)" reads as "a mobile robot that turns in place".
    final s = context.strings;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final kind = _summary?.kind.replaceFirstMapped(RegExp(r'^(.+?) \((.+)\)$'), (m) => '${m[1]} that ${m[2]}');
    final looks = _summary == null || !_summary!.discovered || kind == null ? null
        : '${_summary!.model == null ? 'a' : 'a ${_summary!.model},'} ${kind[0].toLowerCase()}${kind.substring(1)}';
    final localSenses = [
      for (final f in _summary?.features ?? const <RobotFeature>[])
        if (f.detected && const {'lidar', 'camera', 'depth', 'imu', 'navigation', 'arm'}.contains(f.id)) f.labelIn(s),
    ];
    final senses = [
      for (final f in _summary?.features ?? const <RobotFeature>[])
        if (f.detected && const {'lidar', 'camera', 'depth', 'imu', 'navigation', 'arm'}.contains(f.id)) f.label.toLowerCase(),
    ];
    _steps = [
      if (looks != null)
        // In English a sentence; in other languages the summary's own words, listed.
        _Step('kind', s.introLooks(english ? '$looks${senses.isEmpty ? '' : ', with ${senses.join(', ')}'}'
            : [?_summary!.model, _summary!.kindIn(s), ...localSenses].join(' · ')),
            choices: [s.introRight, s.introNotQuite], free: false)
      else
        _Step('kind', s.introUnknown, hint: s.introKindHint),
      _Step('name', s.introName, hint: s.introNameHint,
          choices: {?_summary?.model, ?_robot.profile(RobotPersona.nameKey)}.toList()),
      if (_person.profile(RobotPersona.callPersonKey) == null)
        _Step('call_me', s.introCallMe, hint: s.introCallMeHint),
      _Step('role', s.introRole, hint: s.introRoleHint,
          choices: [s.rolePatrol, s.roleDelivery, s.roleGuide, s.roleResearch, s.roleFun]),
      _Step('tone', s.introTone, choices: [s.toneFriendly, s.toneCalm, s.toneShort, s.tonePlayful]),
      _Step('notes', s.introNotes, hint: s.introNotesHint),
    ];
    setState(() => _said.add((true, _steps.first.question)));
  }

  String get _robotName => _robot.profile(RobotPersona.nameKey) ?? widget.session.name;

  Future<void> _answer(String? text) async {
    if (_at >= _steps.length) return;
    final step = _steps[_at];
    final a = text?.trim() ?? '';
    final s = context.strings;
    setState(() => _said.add((false, a.isEmpty ? s.skipped : a)));
    _input.clear();
    String? follow;
    switch (step.id) {
      case 'kind' when a == s.introNotQuite:
        // One more question before moving on: what kind of robot it really is.
        _steps = [..._steps.take(_at + 1), _Step('kind_free', s.introKindAgain,
            hint: s.introKindAgainHint), ..._steps.skip(_at + 1)];
      case 'kind' when a.isNotEmpty && a != s.introRight:
      case 'kind_free':
        await _robot.setProfile(RobotPersona.kindKey, a);
      case 'name':
        await _robot.setProfile(RobotPersona.nameKey, a);
        if (a.isNotEmpty) follow = s.introNameLiked(a);
      case 'call_me':
        await _person.setProfile(RobotPersona.callPersonKey, a);
      case 'role':
        await _robot.setProfile(RobotPersona.roleKey, a);
      case 'tone':
        await _robot.setProfile(RobotPersona.toneKey, a);
      case 'notes':
        if (a.isNotEmpty) await _robot.add('note', a, pinned: true);
    }
    _at++;
    if (!mounted) return;
    final call = _person.profile(RobotPersona.callPersonKey);
    setState(() {
      if (follow != null) _said.add((true, follow));
      if (_at < _steps.length) {
        _said.add((true, _steps[_at].question));
      } else {
        _said.add((true, s.introDone(call == null ? '' : ', $call', _robotName)));
      }
    });
    if (_at >= _steps.length) await _robot.setProfile(RobotPersona.introducedKey, 'done');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final step = _at < _steps.length ? _steps[_at] : null;
    final large = MediaQuery.textScalerOf(context).scale(10) > 15;
    return SafeArea(child: SizedBox(height: MediaQuery.sizeOf(context).height * (large ? 0.9 : 0.75), child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Row(children: [
        Icon(Icons.smart_toy_outlined, color: theme.colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(child: Text(context.strings.introTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
      ])),
      Expanded(child: ListView(key: const Key('robot-intro-chat'), controller: _scroll, padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [for (final (robot, text) in _said) Align(
          alignment: robot ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: const BoxConstraints(maxWidth: 320),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
                color: robot ? theme.colorScheme.surfaceContainerHighest : theme.colorScheme.primaryContainer),
            child: Text(text)))])),
      if (step != null) Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: Column(children: [
        // One row that scrolls sideways: with large text, wrapped choices pushed the conversation away.
        if (step.choices.isNotEmpty) SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: [
          for (final c in step.choices) Padding(padding: const EdgeInsets.only(right: 8),
              child: ActionChip(key: Key('intro-choice-$c'), label: Text(c), onPressed: () => _answer(c))),
        ])),
        Row(children: [
          if (step.free) Expanded(child: TextField(key: const Key('robot-intro-input'), controller: _input,
              textInputAction: TextInputAction.send, onSubmitted: _answer,
              decoration: InputDecoration(hintText: step.hint, isDense: true)))
          else const Spacer(),
          if (step.free) IconButton(key: const Key('robot-intro-send'), tooltip: context.strings.answer, icon: const Icon(Icons.send),
              onPressed: () => _answer(_input.text)),
          TextButton(key: const Key('robot-intro-skip'), onPressed: () => _answer(null), child: Text(context.strings.skip)),
        ]),
      ]))
      else Padding(padding: const EdgeInsets.all(12), child: FilledButton(key: const Key('robot-intro-done'),
          onPressed: () => Navigator.pop(context), child: Text(context.strings.done))),
    ])));
  }
}
