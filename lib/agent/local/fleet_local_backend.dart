import '../agent.dart';
import '../manifest.dart';
import '../skill.dart';
import '../voice.dart';
import 'local_backend.dart';

/// The on-device model for a fleet. A 2B model cannot reliably write a robot name into every call of a
/// sentence like "robot1 forward 20 cm, robot4 turn left", so the sentence is split by the robot names
/// it mentions (or "all robots") and each part is planned with the one-robot planner and that robot's
/// own tools, which the robot tests already cover. A name that is not in the fleet, or a request that
/// names no robot when there are several, moves nothing.
class FleetLocalBackend extends AgentBackend {
  FleetLocalBackend(this.local);

  final LocalBackend local;

  @override
  String get name => 'local-fleet';

  @override
  Future<AgentPlan> plan(AgentRequest request) async {
    final lang = replyLanguageFor(request.instruction);
    final robots = request.robots;
    if (robots.isEmpty) return local.plan(request); // not a fleet
    // The fleet's own routines name no robot: "run close up", "save what you just did as close up".
    final aliases = request.manifest.fleetAliases;
    final named = robots.keys.any((n) => _nameMatcher(n).hasMatch(request.instruction)) ||
        aliases.keys.any((a) => _aliasMatcher(a).hasMatch(request.instruction));
    if (!named) {
      final routine = fleetRoutineCall(request.instruction, request.manifest);
      if (routine != null) {
        final name = routine.args['name'];
        if (name == null) return LocalPlan(reply: askName(lang));
        return LocalPlan(calls: [routine], reply: routine.name == 'run_routine'
            ? fleetSay(lang, FleetLine.runRoutine, '$name') : fleetSay(lang, FleetLine.saveRoutine, '$name'));
      }
    }
    final parts = splitByRobot(request.instruction, robots.keys.toList(), aliases: aliases);
    if (parts.unknown.isNotEmpty) {
      return LocalPlan(reply: fleetSay(lang, FleetLine.notInFleet, parts.unknown.join(', '), robots.keys.join(', ')));
    }
    if (parts.parts.isEmpty) {
      return LocalPlan(handoff: true, reply: fleetSay(lang, FleetLine.whichRobot, robots.keys.join(', ')));
    }
    final calls = <SkillCall>[];
    final replies = <String>[];
    for (final (names, text) in parts.parts) {
      final first = names.first;
      if (RobotAgent.isStopWord(text)) {
        calls.addAll([for (final name in names) SkillCall('stop', {'robot': name})]);
        continue;
      }
      final plan = await local.plan(AgentRequest(instruction: text, manifest: robots[first]!,
          status: switch (request.status[first]) { final Map<String, Object?> s => s, _ => const {} }));
      final label = names.length == robots.length && robots.length > 1
          ? fleetSay(lang, FleetLine.allRobots)
          : names.map((n) => request.manifest.fleetPersonas[n]?.name ?? n).join(', ');
      // Unsure, or cannot: nothing moves, not even the robots whose part was fine.
      if (plan.handoff) return LocalPlan(handoff: true, reply: '$label: ${plan.reply ?? cannotDo(lang)}');
      if (plan.calls.isEmpty) return LocalPlan(reply: '$label: ${plan.reply ?? cannotDo(lang)}');
      for (final name in names) {
        for (final c in plan.calls) {
          calls.add(SkillCall(c.name, {'robot': name, ...c.args}));
        }
      }
      replies.add('$label: ${plan.reply ?? planSentence(plan.calls, lang)}');
    }
    return LocalPlan(calls: calls, reply: replies.join(' '));
  }

  @override
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) => local.continueWith(results);
}

final _saveWords = RegExp(r'저장|기억해|\bsave\b|\bremember\b|保存|记住|記住|储存|儲存|\bguarda\b|speicher|enregistre|\bsalva\b|'
    r'\bsalve\b|lưu|บันทึก|\bsimpan\b|сохрани', caseSensitive: false);
final _routineWords = RegExp(r'루틴|방금|아까|\broutine\b|\bjust did\b|\bthat\b|ルーティン|ルーチン|さっき|今の|例程|流程|刚才|剛才|'
    r'\brutina\b|acabas de|\bgerade\b|tout à l.heure|\bappena\b|\brotina\b|vừa|quy trình|รูทีน|เมื่อกี้|rutinitas|\btadi\b|'
    r'только что|рутин', caseSensitive: false);

/// A fleet routine request in plain words, or null: running a saved fleet routine named in [instruction],
/// or saving what the fleet just did (a call without a name when none could be found: ask for it).
SkillCall? fleetRoutineCall(String instruction, AgentManifest fleet) {
  final text = instruction.toLowerCase();
  if (fleet.skill('save_routine') != null && _saveWords.hasMatch(text) && _routineWords.hasMatch(text)) {
    final name = routineNameFrom(instruction);
    return SkillCall('save_routine', {'name': ?name});
  }
  final names = fleet.skill('run_routine')?.param('name')?.values ?? const <String>[];
  // The longest name first, so "patrol 2" is not taken for "patrol".
  for (final n in [...names]..sort((a, b) => b.length.compareTo(a.length))) {
    if (text.contains(n.toLowerCase())) return SkillCall('run_routine', {'name': n});
  }
  return null;
}

/// The routine name in "방금 한 거 아침순찰이라는 루틴으로 저장해", "아침순찰로 저장해", "save that as close up".
String? routineNameFrom(String instruction) {
  final t = instruction.trim();
  final named = RegExp(r'(\S+?)\s*(?:이라는|라는)\s*(?:이름의\s*)?루틴').firstMatch(t) ??
      RegExp(r'루틴\s*(?:이름은|이름을)\s*["“‘]?(\S+?)["”’]?\s*(?:이라고|라고|으로|로)\s*(?:저장|기억|이름)').firstMatch(t);
  if (named != null) return named.group(1)!.trim();
  final general = nameFromInstruction(t);
  return general == null || RegExp(r'^(루틴|routine)$', caseSensitive: false).hasMatch(general) ? null : general;
}

/// Words for every robot of the fleet.
final _allWords = RegExp(r'모든\s*로봇|로봇\s*(?:들|전부|모두)|전부|모두|다\s*같이|\ball\s+(?:the\s+)?robots?\b|\bevery\s*(?:robot|one)\b|\beveryone\b|^\s*all\b(?=\s*[,:]|\s+(?:go|move|drive|turn|back|stop|come|forward|rotate)\b)|'
    r'(?:全部|すべて|全て)の?ロボット|ロボット全員|全員|みんな|(?:所有|全部)的?(?:机器人|機器人)|大家|'
    r'\btodos\s+los\s+robots\b|\balle\s+roboter\b|\btous\s+les\s+robots\b|\btout\s+le\s+monde\b|'
    r'\btutti\s+i\s+robot\b|\btodos\s+os\s+robôs\b|tất cả(?:\s+các)?\s+robot|หุ่นยนต์ทุกตัว|'
    r'\bsemua\s+robot\b|все\s+роботы|جميع\s+الروبوتات|सभी\s+रोबोट|\btüm\s+robotlar\b',
    caseSensitive: false);

/// "robot7", "로봇 7", "7번 로봇", "7호기": a robot named by number.
final _numbered = RegExp('${r'(?:\brobot(?:er)?|\brobô|로봇|ロボット|机器人|機器人|หุ่นยนต์|робот)[\s_-]*(\d+)(?!\d)'}$_notAmount|'
    r'(\d+)\s*(?:번\s*로봇|호기|号机|號機|号機)', caseSensitive: false);

/// After a number: not a unit, which makes it an amount ("로봇 30센티" is 30 cm, not robot 30).
const _notAmount = r'(?!\s*(?:cm|mm|m\b|km|센티|센치|미터|도\b|°|%|センチ|メートル|度|厘米|公分|米|公尺|deg|grad|grados|degr|centim|metr|mét|เซนติ|เมตร|องศา|сантим|метр|градус))';

/// Splits [instruction] into (robots, what they should do) by the robot names it mentions.
/// "robot1은 앞으로 가고, robot2는 돌아" → ([robot1], "앞으로 가고"), ([robot2], "돌아");
/// "robot1 and robot2 forward 30 cm" → ([robot1, robot2], "forward 30 cm"); "all robots back" → (all, "back").
/// [unknown] lists robots named by number that are not in [names].
/// [aliases] are the names people gave robots ("순돌이" -> robot1): they count as that robot's name.
({List<(List<String>, String)> parts, List<String> unknown}) splitByRobot(String instruction, List<String> names,
    {Map<String, String> aliases = const {}}) {
  final mentions = <(int, int, String)>[]; // start, end, robot
  final unknown = <String>[];
  for (final name in names) {
    for (final m in _nameMatcher(name).allMatches(instruction)) {
      mentions.add((m.start, m.end, name));
    }
  }
  for (final e in aliases.entries) {
    if (!names.contains(e.value)) continue;
    for (final m in _aliasMatcher(e.key).allMatches(instruction)) {
      mentions.add((m.start, m.end, e.value));
    }
  }
  final known = {for (final n in names) if (RegExp(r'(\d+)$').firstMatch(n) case final m?) m[1]!};
  for (final m in _numbered.allMatches(instruction)) {
    final n = m[1] ?? m[2]!;
    if (!known.contains(n) && !mentions.any((x) => x.$1 < m.end && m.start < x.$2)) unknown.add(m[0]!.trim());
  }
  mentions.sort((a, b) => a.$1.compareTo(b.$1));
  // Overlaps ("robot1" inside "robot10" is excluded by the matcher, but two patterns may hit one span).
  final spans = <(int, int, String)>[];
  for (final m in mentions) {
    if (spans.isEmpty || m.$1 >= spans.last.$2) spans.add(m);
  }
  if (spans.isEmpty) {
    if (names.length == 1) return (parts: [([names.single], _clean(instruction))], unknown: unknown);
    if (_allWords.hasMatch(instruction)) {
      return (parts: [(names, _clean(instruction.replaceAll(_allWords, ' ')))], unknown: unknown);
    }
    return (parts: const [], unknown: unknown);
  }
  final parts = <(List<String>, String)>[];
  var group = <String>[];
  for (var i = 0; i < spans.length; i++) {
    group.add(spans[i].$3);
    final end = i + 1 < spans.length ? spans[i + 1].$1 : instruction.length;
    final text = _clean(instruction.substring(spans[i].$2, end));
    if (text.isEmpty && i + 1 < spans.length) continue; // "robot1 and robot2 ...": they share what follows
    parts.add((group, text.isEmpty ? _clean(instruction.substring(0, spans.first.$1)) : text));
    group = <String>[];
  }
  return (parts: [for (final p in parts) if (p.$2.isNotEmpty) p], unknown: unknown);
}

/// A given name, as a word start (Korean particles may follow: "순돌이는", "Sunny's").
RegExp _aliasMatcher(String alias) =>
    RegExp(r'(?<![\p{L}\p{N}])' + RegExp.escape(alias), caseSensitive: false, unicode: true);

RegExp _nameMatcher(String name) {
  final m = RegExp(r'^(.*?)[\s_-]*(\d+)$').firstMatch(name);
  // "robot1" also as "Robot 1" or "robot_1"; separators inside a name ("tb3_a") may be spaces too.
  String loose(String part) => RegExp.escape(part).replaceAll(RegExp(r'[_\\-]'), r'[\s_-]*');
  final escaped = m == null ? loose(name) : '${loose(m[1]!)}[\\s_-]*${m[2]}';
  final alternatives = [
    '(?<![A-Za-z0-9])$escaped(?!\\d)',
    if (m != null && m[1]!.toLowerCase() == 'robot') ...[
      '로봇\\s*${m[2]}(?!\\d)$_notAmount\\s*(?:번|호기)?',
      '(?<!\\d)${m[2]}\\s*(?:번\\s*로봇|호기|号机|號機|号機)',
      '(?:ロボット|机器人|機器人|roboter|robô|หุ่นยนต์|робот)\\s*${m[2]}(?!\\d)$_notAmount',
    ],
  ];
  return RegExp(alternatives.join('|'), caseSensitive: false);
}

/// Strips what joins a robot's part to the rest: particles after the name, "and"/commas around it.
String _clean(String text) {
  var t = text.trim();
  t = t.replaceFirst(RegExp(r'^(?:은|는|이|가|도|에게|한테|:|,|와|과|랑|하고|and|y|e|et|und|và|dan|и|و)(?=\s|$)\s*', caseSensitive: false), '');
  // Japanese and Chinese particles and joiners come without a space: "robot1は前に", "robot1和robot2".
  t = t.replaceFirst(RegExp(r'^(?:には|は|が|も|に|と|和|跟|与|與|[：:，,、])\s*'), '');
  t = t.replaceFirst(RegExp(r'^[:,]\s*'), '');
  t = t.replaceFirst(RegExp(r'(?:\s*[,;，、；。]\s*|\s*(?:そして|それから|然后|然後|并且|並且)\s*|'
      r'\s+(?:and|then|그리고|y|luego|und|dann|et|puis|e|poi|và|rồi|dan|lalu|и|затем|و|ثم)\s*)$', caseSensitive: false), '');
  return t.trim();
}

enum FleetLine { runRoutine, saveRoutine, notInFleet, whichRobot, allRobots }

/// The fleet's own sentences in the request's language (English for the rest). [a] and [b] fill in names.
String fleetSay(ReplyLanguage lang, FleetLine line, [String a = '', String b = '']) => switch ((lang, line)) {
  (ReplyLanguage.ko, FleetLine.runRoutine) => '"$a" 루틴을 실행할게요.',
  (ReplyLanguage.ko, FleetLine.saveRoutine) => '"$a" 루틴으로 저장할게요.',
  (ReplyLanguage.ko, FleetLine.notInFleet) => '$a은(는) 이 함대에 없어요. 있는 로봇: $b.',
  (ReplyLanguage.ko, FleetLine.whichRobot) => '어느 로봇에게 시킬지 말해 주세요: $a 또는 "모든 로봇".',
  (ReplyLanguage.ko, FleetLine.allRobots) => '모든 로봇',
  (ReplyLanguage.ja, FleetLine.runRoutine) => 'ルーティン「$a」を実行します。',
  (ReplyLanguage.ja, FleetLine.saveRoutine) => 'ルーティン「$a」として保存します。',
  (ReplyLanguage.ja, FleetLine.notInFleet) => '$aはこのフリートにいません。ロボット：$b。',
  (ReplyLanguage.ja, FleetLine.whichRobot) => 'どのロボットにさせるか言ってください：$a、または「全部のロボット」。',
  (ReplyLanguage.ja, FleetLine.allRobots) => '全ロボット',
  (ReplyLanguage.zh, FleetLine.runRoutine) => '运行例程“$a”。',
  (ReplyLanguage.zh, FleetLine.saveRoutine) => '保存为例程“$a”。',
  (ReplyLanguage.zh, FleetLine.notInFleet) => '$a 不在这个车队中。机器人：$b。',
  (ReplyLanguage.zh, FleetLine.whichRobot) => '请说明让哪台机器人做：$a，或“所有机器人”。',
  (ReplyLanguage.zh, FleetLine.allRobots) => '所有机器人',
  (ReplyLanguage.es, FleetLine.runRoutine) => 'Ejecuto la rutina "$a".',
  (ReplyLanguage.es, FleetLine.saveRoutine) => 'Lo guardo como la rutina "$a".',
  (ReplyLanguage.es, FleetLine.notInFleet) => '$a no está en esta flota. Robots: $b.',
  (ReplyLanguage.es, FleetLine.whichRobot) => 'Di qué robot: $a, o "todos los robots".',
  (ReplyLanguage.es, FleetLine.allRobots) => 'Todos los robots',
  (ReplyLanguage.de, FleetLine.runRoutine) => 'Ich starte die Routine „$a“.',
  (ReplyLanguage.de, FleetLine.saveRoutine) => 'Ich speichere das als Routine „$a“.',
  (ReplyLanguage.de, FleetLine.notInFleet) => '$a ist nicht in dieser Flotte. Roboter: $b.',
  (ReplyLanguage.de, FleetLine.whichRobot) => 'Sag, welcher Roboter: $a oder „alle Roboter“.',
  (ReplyLanguage.de, FleetLine.allRobots) => 'Alle Roboter',
  (ReplyLanguage.fr, FleetLine.runRoutine) => 'Je lance la routine « $a ».',
  (ReplyLanguage.fr, FleetLine.saveRoutine) => 'J’enregistre cela comme la routine « $a ».',
  (ReplyLanguage.fr, FleetLine.notInFleet) => '$a n’est pas dans cette flotte. Robots : $b.',
  (ReplyLanguage.fr, FleetLine.whichRobot) => 'Dis quel robot : $a, ou « tous les robots ».',
  (ReplyLanguage.fr, FleetLine.allRobots) => 'Tous les robots',
  (_, FleetLine.runRoutine) => 'Running the routine "$a".',
  (_, FleetLine.saveRoutine) => 'Saving it as the routine "$a".',
  (_, FleetLine.notInFleet) => '$a is not in this fleet. Robots: $b.',
  (_, FleetLine.whichRobot) => 'Say which robot: $a, or "all robots".',
  (_, FleetLine.allRobots) => 'All robots',
};

/// "All robots, stop" in any of the fleet's languages: a stop for every robot, before any model.
bool isFleetStop(String instruction) =>
    _allWords.hasMatch(instruction) && RobotAgent.isStopWord(instruction.replaceAll(_allWords, ' ').replaceAll(RegExp(r'^[\s,，、:：]+'), ''));
