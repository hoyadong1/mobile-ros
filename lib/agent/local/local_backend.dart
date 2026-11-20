import '../learning.dart';
import 'dart:convert';
import '../agent.dart';
import '../manifest.dart';
import '../skill.dart';
import '../voice.dart';
import '../instruction_language.dart';

/// A small language model on the phone: text in, text out, constrained by a GBNF grammar so the output
/// always has the shape asked for. The native implementation is in llm_native.dart; tests use fakes.
abstract class LocalModel {
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160});

  /// Abandons a running [generate] (it then throws).
  void cancel() {}
}

/// A plan from the on-device model. [handoff] means the model judged the request beyond it (it needs
/// the camera, several dependent steps, or knowledge it lacks): a router then asks a bigger model.
class LocalPlan extends AgentPlan {
  const LocalPlan({super.calls, super.reply, this.handoff = false});
  final bool handoff;
}

/// Plans with an on-device model. Small models are weak at free-form tool calling, so the model fills in
/// one JSON answer, `{"say": "...", "calls": [...]}`, whose every call is forced by a grammar built from
/// the manifest to name a real skill with the right argument names and value types. The validator
/// still checks ranges before anything moves.
///
/// Everything is planned up front in one generation; after get_status a second, short generation turns
/// the report into a sentence in the person's language.
class LocalBackend extends AgentBackend {
  LocalBackend(this.model, {this.maxCalls = 5});

  final LocalModel model;
  final int maxCalls;
  ReplyLanguage _lang = ReplyLanguage.en;

  @override
  String get name => 'local';

  @override
  Future<LocalPlan> plan(AgentRequest request) async {
    _lang = replyLanguageFor(request.instruction);
    // Explicit memory writes contain user data (names/notes in any language), not actions to guess.
    final memo = memoryCall(request.instruction, request.manifest);
    if (memo != null) return LocalPlan(calls: [memo], reply: planSentence([memo], _lang));
    if (InstructionLanguagePolicy.needsOnline(request.instruction, request.manifest)) {
      return LocalPlan(handoff: true, reply: InstructionLanguagePolicy.unavailable(request.instruction, request.manifest));
    }
    // Direct motion in the other measured languages is read by its grammar (a 2B model sometimes refused
    // "rẽ phải 90 độ" once a robot had saved places).
    final direct = InstructionLanguagePolicy.directCalls(request.instruction, request.manifest);
    if (direct != null) return LocalPlan(calls: direct, reply: planSentence(direct, _lang));
    // A learned tool asked for in the person's own words, or "as usual": no model needed.
    final learned = Learning.directCall(request.instruction, request.manifest.learned);
    if (learned != null) return LocalPlan(calls: [learned], reply: planSentence([learned], _lang));
    // The person's own words for things ("거기" = 부엌) are put plainly before anything reads the request.
    if (request.manifest.aliases.isNotEmpty) {
      final plain = Learning.rewrite(request.instruction, request.manifest.aliases);
      if (plain != request.instruction) {
        // Planned again without the phrase list, so a meaning that holds its own phrase cannot loop.
        return this.plan(AgentRequest(instruction: plain, manifest: request.manifest.without(const {}, aliases: false),
            status: request.status, robots: request.robots));
      }
    }
    // Asked for something this robot has no skill for: do not let the small model improvise.
    final missing = missingAbility(request.instruction, request.manifest);
    if (missing != null) return LocalPlan(handoff: true, reply: lacking(missing, _lang));
    final text = await model.generate(
      // The instructions stay the same between requests, so the model reuses what it already read
      // (2-3 s instead of ~13 s on a PC CPU); the language hint goes with the request.
      // Neither memory skills nor learned tools are the small model's to choose (see above), and its
      // instructions stay the same from one request to the next.
      system: localSystemPrompt(request.manifest.without(_notForModel(request.manifest))),
      user: request.instruction,
      grammar: skillGrammar(request.manifest.without(_notForModel(request.manifest)), maxCalls: maxCalls),
      maxTokens: 200,
    );
    final parsed = parseLocalAnswer(text);
    final plan = keepNamesAsSaid(parsed, request.instruction, request.manifest);
    if (plan == null && parsed.calls.any((c) => c.name == 'arm_to_pose')) {
      // No saved posture matches what was asked: hand it on (a bigger model can explain) or say so.
      final names = request.manifest.armPoses.join(', ');
      return LocalPlan(handoff: true, reply: _lang == ReplyLanguage.ko
          ? '저장된 팔 자세 중에 맞는 게 없어요. 저장된 자세: $names.'
          : 'No saved arm posture matches that. Saved postures: $names.');
    }
    if (plan == null) return LocalPlan(reply: askName(_lang));
    // Saved places named in the request but missing from the plan: a 2B model often drops the second
    // of two places ("kitchen, then the charging dock"). Hand it on rather than go to only one.
    final named = _placesNamed(request.instruction, request.manifest);
    final trips = plan.calls.where((c) => c.name == 'go_to_place').length;
    // Names said in another word than saved ("부엌" for "kitchen") are not counted: "A에 갔다가 B로" still
    // says two stops, so one planned stop is handed on too.
    if ((named > 1 && trips < named) || (trips == 1 && _twoStops.hasMatch(request.instruction))) {
      return const LocalPlan(handoff: true);
    }
    // The model's own "say" helps it plan (written first, it keeps a small model from dropping the
    // second action) but is not shown: it follows the examples' language and may translate names.
    // The person reads a sentence made from the calls, in their language (see voice.dart).
    if (plan.calls.isNotEmpty) {
      return LocalPlan(calls: plan.calls, reply: planSentence(plan.calls, _lang), handoff: plan.handoff);
    }
    final say = plan.reply;
    final sameLanguage = say != null && hasHangul(say) == (_lang == ReplyLanguage.ko);
    return LocalPlan(handoff: plan.handoff, reply: plan.handoff ? null : sameLanguage ? say : cannotDo(_lang));
  }

  @override
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) async {
    // Answers to questions (status, battery, problems) come from the results' figures, not the model.
    final answers = [
      for (final (call, r) in results)
        if (reportSkills.contains(call.name)) ?reportSentence(call, r, _lang),
    ];
    return AgentPlan(reply: answers.isEmpty ? null : answers.join(' '));
  }
}

/// A name to save under (a place, a routine, a map) is the person's own word: a 2B model translated
/// "kitchen" into "부엌" after the Korean example, and turned a bare "Save" into a place called "저장".
/// A free-text name that does not appear in [instruction] is replaced by the one the instruction gives
/// ("... as kitchen", "부엌으로 저장해"); when none can be found the plan is dropped (null) so the person
/// is asked. A map name may simply be left out (it gets a dated one).
LocalPlan? keepNamesAsSaid(LocalPlan plan, String instruction, AgentManifest m) {
  final said = instruction.toLowerCase();
  final calls = <SkillCall>[];
  for (final c in plan.calls) {
    // An arm posture must be one the person named ("home" also by its plain words). Found on the arm
    // simulator: "stretch the arm up", which matches no saved posture, was sent to "home".
    if (c.name == 'arm_to_pose') {
      final pose = '${c.args['name']}'.toLowerCase().trim();
      if (!said.contains(pose) && !(pose == 'home' && _homeWords.hasMatch(said))) return null;
    }
    final name = c.args['name'];
    final param = m.skill(c.name)?.param('name');
    if (name is! String || param == null || param.values != null || said.contains(name.toLowerCase().trim())) {
      calls.add(c);
      continue;
    }
    final fromText = nameFromInstruction(instruction);
    if (fromText != null) {
      calls.add(SkillCall(c.name, {...c.args, 'name': fromText}, c.id));
    } else if (!param.required) {
      calls.add(SkillCall(c.name, {...c.args}..remove('name'), c.id));
    } else {
      return null;
    }
  }
  return LocalPlan(calls: calls, reply: plan.reply, handoff: plan.handoff);
}

final _homeWords = RegExp(r'홈|원래|처음|초기|기본|접어|제자리로|\bhome\b|\brest\b|\bdefault\b|\bfold');

/// The name a request gives: "save this spot as kitchen", "call it front door", "부엌으로 저장해",
/// "아침순찰이라고 저장".
String? nameFromInstruction(String instruction) {
  final t = instruction.trim();
  final english = RegExp(r'''\b(?:as|called|named|name it|call it)\s+["'“‘]?([^"'”’.,!?]+?)["'”’]?\s*[.!?]*$''',
      caseSensitive: false).firstMatch(t);
  if (english != null) return english.group(1)!.trim();
  final quoted = RegExp(r'''["'“‘]([^"'”’]+)["'”’]''').firstMatch(t);
  if (quoted != null) return quoted.group(1)!.trim();
  final korean = RegExp(r'(\S+?)(?:이라고|라고|으로|로)\s*(?:저장|기억|이름)').firstMatch(t);
  if (korean != null) return korean.group(1)!.trim();
  return null;
}

Set<String> _notForModel(AgentManifest m) => {...memorySkills, for (final t in m.learned) t.name};

/// Skills that write the assistant's memory: chosen by [memoryCall], never by the small model.
const memorySkills = {'update_profile', 'remember', 'learn_phrase', 'define_tool'};

/// What [instruction] asks the robot to remember, as a call, or null. Plain patterns: Korean and English
/// ("나를 민수라고 불러", "call me Minsu", "네 이름은 순돌이야", "your name is Sunny", "너는 순찰 담당이야",
/// "2층 계단 근처는 가지 마, 기억해", "remember that the door sticks"), and the nickname, the robot's name
/// and "remember …" in Japanese, Chinese, Spanish, German, French, Italian and Portuguese: kept word for
/// word, without a model and without the internet.
SkillCall? memoryCall(String instruction, AgentManifest m) {
  if (m.skill('update_profile') == null) return null;
  final t = instruction.trim().replaceAll(RegExp(r'[.!~。！]+$'), '').trim();
  String? first(List<RegExp> patterns) {
    for (final p in patterns) {
      final g = p.firstMatch(t)?.group(1)?.trim();
      if (g != null && g.isNotEmpty && g.length <= 40) {
        return g.replaceAll(RegExp(r'''^["'“‘「]|["'”’」]$'''), '')
            .replaceAll(RegExp(r'\s*(?:吧|哦|喔|呀|ね|よ|, por favor|, bitte|, per favore|, s.il te pla[iî]t)$'), '').trim();
      }
    }
    return null;
  }
  // A question about these ("네 이름은 뭐야?", "나를 뭐라고 불러?") is not telling: found on review, asking
  // the robot's name renamed it "뭐야?".
  final asking = t.endsWith('?') || t.endsWith('？') || _asking.hasMatch(t);
  final callMe = first([
    RegExp(r'(?:나를|날|저를|절|나는|저는)\s*(?:앞으로\s*)?["“‘]?(.+?)["”’]?\s*(?:이)?라고\s*(?:불러|부르)'),
    RegExp(r'\bcall me\s+(.+)$', caseSensitive: false),
    RegExp(r'(?:私|わたし|僕|ぼく|俺)を\s*「?(.+?)」?\s*(?:って|と)\s*呼んで'),
    // Anchored: "他叫我过去" (he asked me over) is not a nickname.
    RegExp(r'^(?:以后|以後|今后|今後|从现在开始|從現在開始)?[，,]?\s*(?:请|請|你可以)?\s*(?:叫我|称呼我为?|稱呼我為?)\s*(.+)$'),
    RegExp(r'\b(?:llámame|me puedes llamar)\s+(.+)$', caseSensitive: false),
    RegExp(r'\bnenn(?:e)? mich(?:\s+(?:ab jetzt|von nun an|bitte))?\s+(.+)$', caseSensitive: false),
    RegExp(r'\bappel(?:le|ez)-moi\s+(.+)$', caseSensitive: false),
    RegExp(r'\bchiamami\s+(.+)$', caseSensitive: false),
    RegExp(r'\b(?:me cham[ae] de|chame-me(?: de)?)\s+(.+)$', caseSensitive: false),
    RegExp(r'gọi tôi là\s+(.+)$', caseSensitive: false),
    RegExp(r'เรียก(?:ฉัน|ผม|หนู|เรา)ว่า\s*(.+)$'),
  ]);
  if (callMe != null && !asking) return SkillCall('update_profile', {'field': 'call_person', 'value': callMe});
  final name = first([
    RegExp(r'(?:너|네|니|당신)\s*(?:의\s*)?이름은\s*["“‘]?(.+?)["”’]?\s*(?:야|예요|에요|입니다|다|으로 하자|로 하자|으로 해|로 해)?$'),
    RegExp(r'(?:너|네|니)\s*(?:를|을)?\s*["“‘]?(.+?)["”’]?\s*(?:이)?라고\s*(?:부를게|부르자|할게)'),
    RegExp(r'\byour name is\s+(.+)$', caseSensitive: false),
    RegExp(r"\bi(?:'ll| will) call you\s+(.+)$", caseSensitive: false),
    RegExp(r'(?:君|きみ|あなた|お前)の名前は\s*「?(.+?)」?\s*(?:だよ|です|だ|ね|にする|にしよう)?$'),
    RegExp(r'你的名字(?:是|叫)\s*(.+)$'),
    RegExp(r'\b(?:tu nombre es|te llamas)\s+(.+)$', caseSensitive: false),
    RegExp(r'\b(?:dein name ist|du heißt)\s+(.+)$', caseSensitive: false),
    RegExp(r"\b(?:ton nom est|tu t['’]appelles)\s+(.+)$", caseSensitive: false),
    RegExp(r'\b(?:il tuo nome è|ti chiami)\s+(.+)$', caseSensitive: false),
    RegExp(r'\b(?:seu nome é|você se chama)\s+(.+)$', caseSensitive: false),
  ]);
  if (name != null && !asking) return SkillCall('update_profile', {'field': 'robot_name', 'value': name});
  final role = first([
    RegExp(r'(?:너는|넌|너의\s*일은|네\s*일은)\s*(.+?)\s*(?:담당|담당이야|담당이다|하는\s*로봇이야|용이야|용도야)$'),
    RegExp(r'\byour job is\s+(?:to\s+)?(.+)$', caseSensitive: false),
  ]);
  if (role != null && !asking) return SkillCall('update_profile', {'field': 'robot_role', 'value': role});
  final phrase = RegExp(r'^["“‘]?(.+?)["”’]?\s*(?:이라고 하면|라고 하면|이라고 말하면|라고 말하면|은|는)\s*["“‘]?(.+?)["”’]?\s*(?:이라는|라는)\s*(?:뜻|말|의미)(?:이야|야|이에요|예요|입니다)?$').firstMatch(t) ??
      RegExp(r'^when i say\s+["“‘]?(.+?)["”’]?,?\s+i mean\s+(.+)$', caseSensitive: false).firstMatch(t) ??
      RegExp(r'^by\s+["“‘](.+?)["”’]\s+i mean\s+(.+)$', caseSensitive: false).firstMatch(t);
  if (phrase != null && m.skill('learn_phrase') != null) {
    return SkillCall('learn_phrase', {'phrase': phrase.group(1)!.trim(), 'meaning': phrase.group(2)!.trim()});
  }
  final note = RegExp(r'^(?:이거\s*)?(?:기억해|명심해|잊지\s*마)[:,]?\s*(.+)$').firstMatch(t)?.group(1) ??
      RegExp(r'^(.+?)[,.]?\s*(?:꼭\s*)?(?:기억해(?:\s*둬)?|명심해|잊지\s*마)$').firstMatch(t)?.group(1) ??
      RegExp(r'^(?:please\s+)?(?:remember|keep in mind|note)(?:\s+that)?[:,]?\s+(.+)$', caseSensitive: false).firstMatch(t)?.group(1) ??
      _otherNote.map((p) => p.firstMatch(t)?.group(1)).nonNulls.firstOrNull;
  if (note != null && note.trim().length >= 2) return SkillCall('remember', {'note': note.trim()});
  return null;
}

final _asking = RegExp(r'뭐|무엇|뭔지|누구|어떻게|어디|언제|몇|\bwhat\b|\bwho\b|\bhow\b|\bwhere\b|\bwhen\b|'
    r'何|なんて|什么|什麼|甚麼|誰|谁|吗|嗎|^¿|\bqué\b|\bcómo\b|\bwie\b|\bwas\b|\bcomment\b|\bquoi\b|\bcosa\b|\bcomo\b|\bo que\b',
    caseSensitive: false);

/// "Remember …" in Japanese, Chinese, Spanish, German, French, Italian and Portuguese.
final _otherNote = [
  RegExp(r'^(?:覚えておいて|覚えて)[:：、,]?\s*(.+)$'),
  RegExp(r'^(.+?)(?:って|と|を)?\s*覚えておいて$'),
  RegExp(r'^(?:请记住|請記住|记住|記住)[:：，,]?\s*(.+)$'),
  RegExp(r'^(?:recuerda|acuérdate de)(?:\s+que)?[:,]?\s+(.+)$', caseSensitive: false),
  RegExp(r'^(?:merk dir|merke dir)(?:,?\s+dass)?[:,]?\s+(.+)$', caseSensitive: false),
  RegExp(r'^(?:souviens-toi|rappelle-toi|retiens)(?:\s+que)?[:,]?\s+(.+)$', caseSensitive: false),
  RegExp(r'^(?:ricorda|ricordati)(?:\s+che)?[:,]?\s+(.+)$', caseSensitive: false),
  RegExp(r'^(?:lembre-se|lembra-te|lembre|lembra)(?:\s+(?:de\s+)?que)?[:,]?\s+(.+)$', caseSensitive: false),
];

/// Skills whose result answers a question: the small model turns their report into a sentence.
const reportSkills = {'get_status', 'check_robot'};

/// What [instruction] asks for that the robot has no skill for (sideways motion, turning in place, going
/// to a point on a map), as a sentence for the person, or null. A plain word check, on purpose: with only
/// "move" on offer a 2B model turned "slide sideways 50 cm" into a 50 cm drive forward and "go to (2, 1)
/// on the map" into 2 m straight ahead, and examples did not cure it. A hit hands the request to the
/// bigger model, or refuses it when there is none.
String? missingAbility(String instruction, AgentManifest m) {
  final text = instruction.toLowerCase();
  bool has(String skill) => m.skill(skill) != null;
  if (!has('strafe') && _sideways.hasMatch(text)) return 'This robot cannot move sideways.';
  if (!has('rotate') && _turning.hasMatch(text)) return 'This robot cannot turn in place.';
  // An arm the assistant has no skill for (found on a TurtleBot3 with an arm: "raise the arm" became
  // a 0.5 m drive forward).
  if (!m.skills.any((k) => k.name.contains('arm') || k.name.contains('grip')) && _arm.hasMatch(text)) {
    return 'The assistant cannot move the arm or gripper. Use the control screen for the arm.';
  }
  // "Save the map" while mapping talks about the map without asking to go anywhere on it.
  final savingMap = has('save_map') && _saving.hasMatch(text);
  if (!has('navigate_to') && !has('go_to_place') && !savingMap && _mapGoal.hasMatch(text)) {
    return 'This robot has no map navigation.';
  }
  return null;
}

final _arm = RegExp(r'팔을|팔로|팔 |로봇팔|그리퍼|집게|집어|잡아|들어\s?올|내려놓|\barm\b|\bgripper\b|\bgrasp|\bgrab|\bpick (it |this |that |the \w+ )?up|\blift\b');
final _sideways = RegExp(r'옆으로|게걸음|횡이동|sideways|sidestep|strafe|slide (to the )?(left|right)|crab');
final _turning = RegExp(r'제자리|돌아|돌려|돌고|회전|\bturn|\brotate|\bspin|\bpivot');
final _saving = RegExp(r'save|저장|기록');
final _mapGoal = RegExp(r'지도|좌표|\bmap\b|coordinate|\(\s*-?\d+(\.\d+)?\s*,\s*-?\d');

/// Skills whose signed amount the small model gets as a direction word and a positive amount instead:
/// a 2B model picks "left" or "right" reliably but often gets the sign of an angle wrong. The answer is
/// turned back into the signed form before the validator sees it.
/// skill → (amount parameter, word for positive, word for negative).
const directional = {
  'move': ('distance_m', 'forward', 'backward'),
  'strafe': ('distance_m', 'left', 'right'),
  'rotate': ('angle_deg', 'left', 'right'),
};

/// The on-device model's instructions: short, with the actions spelled out and examples, since a 2B
/// model follows examples better than rules.
String localSystemPrompt(AgentManifest m) {
  final offered = {for (final s in m.skills) s.name};
  final lines = <String>[
    'You control a robot through a phone app. Reply with JSON only: {"say": "...", "calls": [...]}.',
    '"say" first names every action you will do, in one short sentence in their language. '
        '"calls" then lists those actions, in order.',
    'Actions:',
    for (final s in m.skills)
      if (s.name != 'look')
        '- ${s.name}${s.params.isEmpty ? '' : ' (${_hints(s).join(', ')})'}: ${_describe(s)}',
    '- handoff: use it alone when the request needs the camera or seeing, information you do not have, '
        'or steps that depend on what happens first, or when you are unsure.',
    'If it is not a robot action or the robot cannot do it, use no calls and say why. Never do a different '
        'action instead of the one asked for.',
    'Distances are metres (50 cm = 0.5), always positive: say the way with "direction". '
        '왼쪽 = left, 오른쪽 = right, 앞 = forward, 뒤 = backward. '
        'A turn without an angle is 90 degrees. Do every action the person asks for, in order, in any language.',
    'Robot: ${m.describe(brief: true)}',
    'Examples:',
    if (offered.contains('move')) ...[
      'User: 앞으로 50센티 가',
      '{"say": "앞으로 50센티 갈게요.", "calls": [{"skill": "move", "direction": "forward", "distance_m": 0.5}]}',
    ],
    if (offered.contains('rotate') && offered.contains('move')) ...[
      'User: 왼쪽으로 45도 돌고 1미터 앞으로 가',
      '{"say": "왼쪽으로 45도 돌고 1미터 갈게요.", "calls": [{"skill": "rotate", "direction": "left", "angle_deg": 45}, {"skill": "move", "direction": "forward", "distance_m": 1}]}',
      'User: 오른쪽으로 돌고 20센티 뒤로 가',
      '{"say": "오른쪽으로 돌고 20센티 뒤로 갈게요.", "calls": [{"skill": "rotate", "direction": "right", "angle_deg": 90}, {"skill": "move", "direction": "backward", "distance_m": 0.2}]}',
      // Not only Korean: a 2B model copies the language of its multi-step examples.
      'User: go back 1 m and turn left',
      '{"say": "Backing up 1 m, then turning left.", "calls": [{"skill": "move", "direction": "backward", "distance_m": 1}, {"skill": "rotate", "direction": "left", "angle_deg": 90}]}',
    ],
    if (offered.contains('go_to_place')) ...[
      'User: ${m.places.first.name}(으)로 가줘',
      '{"say": "${m.places.first.name}(으)로 갈게요.", "calls": [{"skill": "go_to_place", "name": ${jsonEncode(m.places.first.name)}}]}',
    ],
    if (offered.contains('save_routine')) ...[
      'User: 방금 한 거 아침순찰이라는 루틴으로 저장해',
      '{"say": "아침순찰로 저장할게요.", "calls": [{"skill": "save_routine", "name": "아침순찰"}]}',
    ],
    if (offered.contains('run_routine')) ...[
      'User: ${m.routines.first} 실행해',
      '{"say": "${m.routines.first}을(를) 실행할게요.", "calls": [{"skill": "run_routine", "name": ${jsonEncode(m.routines.first)}}]}',
    ],
    // What this robot lacks, spelled out: without these a 2B model does something else instead (on a
    // car without a map, "go to (2, 1) on the map" became a 2 m drive straight ahead).
    if (!offered.contains('navigate_to')) ...[
      'User: 지도에서 (1, 2)로 이동해',
      '{"say": "이 로봇은 지도 내비게이션을 할 수 없어요.", "calls": []}',
    ],
    if (!offered.contains('rotate') && offered.contains('move')) ...[
      'User: 제자리에서 오른쪽으로 돌아',
      '{"say": "이 로봇은 제자리에서 돌 수 없어요. 앞뒤로만 갈 수 있어요.", "calls": []}',
    ],
    if (!offered.contains('strafe') && offered.contains('move')) ...[
      'User: 옆으로 게걸음으로 30센티 가',
      '{"say": "이 로봇은 옆으로 이동할 수 없어요.", "calls": []}',
    ],
    if (offered.contains('arm_to_pose')) ...[
      'User: 팔을 ${m.armPoses.first} 자세로',
      '{"say": "팔을 ${m.armPoses.first} 자세로 움직일게요.", "calls": [{"skill": "arm_to_pose", "name": ${jsonEncode(m.armPoses.first)}}]}',
    ],
    if (offered.contains('gripper')) ...[
      'User: 그리퍼 닫아',
      '{"say": "그리퍼를 닫을게요.", "calls": [{"skill": "gripper", "action": "close"}]}',
    ],
    'User: 지금 상태 알려줘',
    '{"say": "상태를 확인할게요.", "calls": [{"skill": "get_status"}]}',
    if (offered.contains('check_robot')) ...[
      'User: 배터리 얼마나 남았어?',
      '{"say": "배터리를 확인할게요.", "calls": [{"skill": "check_robot"}]}',
      'User: is anything wrong with the robot?',
      '{"say": "Checking the robot.", "calls": [{"skill": "check_robot"}]}',
    ],
    if (offered.contains('find_position')) ...[
      'User: 위치 다시 잡아줘',
      '{"say": "지도와 맞춰 위치를 찾을게요.", "calls": [{"skill": "find_position"}]}',
      'User: the robot is lost',
      '{"say": "Finding its position on the map.", "calls": [{"skill": "find_position"}]}',
    ],
    // A name is copied as written, in the person's language: a Korean-only example made the model
    // translate "front door" into Korean.
    if (offered.contains('save_place')) ...[
      'User: 여기를 부엌으로 저장해',
      '{"say": "여기를 부엌으로 저장할게요.", "calls": [{"skill": "save_place", "name": "부엌"}]}',
      'User: save this spot as garage',
      '{"say": "Saving this spot as garage.", "calls": [{"skill": "save_place", "name": "garage"}]}',
    ],
    if (offered.contains('save_map')) ...[
      'User: 지도 저장해줘',
      '{"say": "지도를 저장할게요.", "calls": [{"skill": "save_map"}]}',
    ],
    'User: 앞에 뭐가 보여?',
    '{"say": "", "calls": [{"skill": "handoff"}]}',
    'User: 하늘로 날아',
    '{"say": "로봇은 날 수 없어요. 이동이나 회전은 할 수 있어요.", "calls": []}',
  ];
  return lines.join('\n');
}

List<String> _hints(Skill s) {
  final dir = directional[s.name];
  return [
    if (dir != null) 'direction: ${dir.$2}|${dir.$3}',
    for (final p in s.params)
      if (dir != null && p.name == dir.$1)
        '${p.name}: 0..${_n(p.max ?? 0)}${p.unit == null ? '' : ' ${p.unit}'}'
      else
        _paramHint(p),
  ];
}

/// The skill's description without sign conventions, which the direction word replaces.
String _describe(Skill s) => switch (s.name) {
  'move' => 'Drive straight forward or backward by a distance, then stop.',
  'strafe' => 'Slide sideways to the left or right without turning.',
  'rotate' => 'Turn in place to the left or right by an angle.',
  'save_routine' => 'Save the actions just done as a routine. The name is copied exactly as the person said it, '
      'never translated or changed.',
  'save_place' => 'Save where the robot is now as a named place. The name is copied exactly as the person said it, '
      'never translated or changed.',
  _ => s.description,
};

String _paramHint(SkillParam p) {
  final range = p.values != null
      ? p.values!.join('|')
      : p.min != null && p.max != null
          ? '${_n(p.min!)}..${_n(p.max!)}'
          : p.type.name;
  return '${p.name}: $range${p.unit == null ? '' : ' ${p.unit}'}${p.required ? '' : ', optional'}';
}

String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : '$v';

/// A GBNF grammar (llama.cpp) for `{"say": "...", "calls": [...]}` where each call is one of the
/// manifest's skills (except `look`: the small model cannot see) or `handoff`, with its parameters in a
/// fixed order: required ones always, optional ones may be left out, enum values from the allowed set.
String skillGrammar(AgentManifest m, {int maxCalls = 5}) {
  final alternatives = <String>[];
  final rules = <String>[];
  for (final s in m.skills) {
    if (s.name == 'look') continue;
    final rule = 'c-${s.name.replaceAll('_', '-')}';
    alternatives.add(rule);
    final b = StringBuffer('$rule ::= "{" ws ${_lit('"skill"')} ws ":" ws ${_lit(jsonEncode(s.name))}');
    final dir = directional[s.name];
    if (dir != null) {
      b.write(' ws "," ws ${_lit('"direction"')} ws ":" ws (${_lit(jsonEncode(dir.$2))} | ${_lit(jsonEncode(dir.$3))})');
    }
    for (final p in s.params) {
      final value = p.values != null
          ? '(${p.values!.map((v) => _lit(jsonEncode(v))).join(' | ')})'
          : p.type == ParamType.number ? (dir != null && p.name == dir.$1 ? 'unum' : 'num') : 'str';
      final part = 'ws "," ws ${_lit(jsonEncode(p.name))} ws ":" ws $value';
      b.write(p.required ? ' $part' : ' ($part)?');
    }
    b.write(' ws "}"');
    rules.add(b.toString());
  }
  alternatives.add('c-handoff');
  rules.add('c-handoff ::= "{" ws ${_lit('"skill"')} ws ":" ws ${_lit('"handoff"')} ws "}"');
  return [
    // "say" comes first: writing the plan as a sentence before the calls keeps a small model from
    // stopping after the first action (measured in 12 languages: 2-step commands 1/12 -> 12/12,
    // all commands 25/36 -> 35/36; tool/live_local_languages_test.dart).
    'root ::= "{" ws ${_lit('"say"')} ws ":" ws str ws "," ws ${_lit('"calls"')} ws ":" ws "[" ws calls? ws "]" ws "}"',
    'calls ::= call (ws "," ws call){0,${maxCalls - 1}}',
    'call ::= ${alternatives.join(' | ')}',
    ...rules,
    _common,
  ].join('\n');
}

const _common = r'''num ::= "-"? unum
unum ::= [0-9]{1,4} ("." [0-9]{1,3})?
str ::= "\"" chr{0,200} "\""
chr ::= [^"\\\x00-\x1F\x7F] | "\\" ["\\nt]
ws ::= " "?''';


/// A GBNF string literal.
String _lit(String s) => '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// Reads the model's answer. Unknown or malformed parts are dropped rather than guessed at.
LocalPlan parseLocalAnswer(String text) {
  final Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    throw FormatException('The on-device model gave an unreadable answer: $text');
  }
  if (json is! Map) throw FormatException('The on-device model gave an unreadable answer: $text');
  final say = json['say'] is String ? (json['say'] as String).trim() : '';
  final calls = <SkillCall>[];
  var handoff = false;
  final raw = json['calls'];
  if (raw is List) {
    for (final (i, c) in raw.indexed) {
      if (c is! Map || c['skill'] is! String) continue;
      final name = c['skill'] as String;
      if (name == 'handoff') {
        handoff = true;
        continue;
      }
      final args = {for (final e in c.entries) if (e.key != 'skill' && e.key != 'direction') '${e.key}': e.value};
      final dir = directional[name];
      final amount = dir == null ? null : args[dir.$1];
      if (dir != null && amount is num) {
        // Back to the signed form the skill takes: the word for negative flips the sign.
        args[dir.$1] = c['direction'] == dir.$3 ? -amount.abs() : amount.abs();
      }
      calls.add(SkillCall(name, args, 'local:$i'));
    }
  }
  return LocalPlan(calls: handoff ? const [] : calls, reply: say.isEmpty ? null : say, handoff: handoff);
}

/// How many of the robot's saved places [instruction] names, word for word.
int _placesNamed(String instruction, AgentManifest m) => m.places.where((p) => p.name.trim().isNotEmpty &&
    RegExp(r'(?<![\p{L}\p{N}_])' + RegExp.escape(p.name.trim()) + r'(?![\p{L}\p{N}_])', unicode: true, caseSensitive: false)
        .hasMatch(instruction)).length;

/// "Go to A, then B" in words that need two stops.
final _twoStops = RegExp(r'갔다가|들렀다가?|거쳐서?|찍고|\bthen\b|\bafter that\b|\band (?:come )?back to\b', caseSensitive: false);
