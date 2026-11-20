import 'memory.dart';

/// Who a robot is to its person, read from memory: the name they gave it, what it is for, how it
/// talks, what kind of robot they say it is, what to call the person, and notes to keep in mind.
/// One AI serves every robot; this is what makes each one itself. See [Memory] for where it lives.
class RobotPersona {
  const RobotPersona({this.name, this.role, this.tone, this.kind, this.callPerson, this.notes = const [],
      this.recent = const [], this.now});

  /// Profile keys in a robot's memory, and in the person's ([callPersonKey]).
  static const nameKey = 'name', roleKey = 'role', toneKey = 'tone', kindKey = 'kind';
  static const callPersonKey = 'call_me';
  /// Set once the first-meeting conversation was had (or put off), so it is not offered again.
  static const introducedKey = 'introduced';

  /// What [update_profile] may set, and where: the assistant can change these and nothing else.
  static const fields = {
    'robot_name': nameKey, 'robot_role': roleKey, 'robot_tone': toneKey, 'robot_kind': kindKey,
    'call_person': callPersonKey,
  };

  final String? name, role, tone, kind;
  /// What the robot should call its person ("Minsu", "boss").
  final String? callPerson;
  final List<String> notes;
  /// What happened lately with this robot (requests and how they went), oldest first; see [episodeText].
  final List<String> recent;
  /// The time the persona was read, so "earlier today" or "yesterday" can be told apart.
  final DateTime? now;

  bool get isEmpty => name == null && role == null && tone == null && kind == null && callPerson == null &&
      notes.isEmpty && recent.isEmpty;

  /// The persona of the robot whose memory is [robot], for the person in [person]. Notes are the most
  /// relevant to [query] that fit (all pinned ones first).
  /// Recent events are the most relevant to [query] within [recentBudget], in the order they happened.
  static RobotPersona from(Memory robot, Memory person, {String query = '', int budget = 600, int recentBudget = 700,
      DateTime? now}) {
    final notes = robot.relevant(query, budget: budget);
    final recent = robot.relevant(query, kinds: const {'episode'}, budget: recentBudget)
      ..sort((a, b) => a.created.compareTo(b.created));
    return RobotPersona(name: robot.profile(nameKey), role: robot.profile(roleKey), tone: robot.profile(toneKey),
        kind: robot.profile(kindKey), callPerson: person.profile(callPersonKey),
        notes: [for (final n in notes) n.text], recent: [for (final e in recent) e.text], now: now ?? DateTime.now());
  }

  /// One line for the robot's memory about a request and how it went:
  /// `2026-11-18 09:12 "앞으로 20센티 가" -> Moved 0.19 m forward.` Null when there is nothing worth keeping.
  static String? episodeText(DateTime at, String instruction, {List<String> results = const [], List<String> replies = const [],
      String? error}) {
    final what = [...results, if (error != null) 'Not done: $error', if (results.isEmpty && error == null) ...replies]
        .where((s) => s.trim().isNotEmpty).join(' ');
    if (instruction.trim().isEmpty || what.isEmpty) return null;
    final ask = instruction.trim().length > 80 ? '${instruction.trim().substring(0, 80)}...' : instruction.trim();
    final told = what.length > 160 ? '${what.substring(0, 160)}...' : what;
    return '${stamp(at)} "$ask" -> $told';
  }

  static String stamp(DateTime t) => '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
  static String _two(int n) => n.toString().padLeft(2, '0');

  /// A few lines for the assistant's instructions: it speaks as this robot, to this person. Without
  /// [withRecent] the lines stay the same from one request to the next (the on-device model reuses them).
  String describe({bool withRecent = true}) {
    if (isEmpty) return '';
    return [
      if (name != null) 'The person named this robot "$name"; it answers to that name and may call itself that.',
      if (kind != null) 'The person says it is: $kind.',
      if (role != null) 'It is here for: $role.',
      if (tone != null) 'Its manner of speaking: $tone. Keep replies short.',
      if (callPerson != null) 'Call the person "$callPerson".',
      if (notes.isNotEmpty) 'The person asked it to keep in mind: ${notes.join('; ')}.',
      if (withRecent && recent.isNotEmpty)
        'It is now ${stamp(now ?? DateTime.now())}. What happened lately (oldest first): ${recent.join(' | ')}. '
        'Use it when the person refers to earlier, e.g. "like yesterday" or "what did you do".',
    ].where((s) => s.isNotEmpty).join(' ');
  }
}
