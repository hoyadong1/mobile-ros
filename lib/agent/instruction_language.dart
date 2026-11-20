import 'manifest.dart';
import 'skill.dart';

/// Routing hints, not a general-purpose language detector. Only complete, bounded direct-motion
/// sentences in the measured languages may bypass the online interpretation fallback.
enum InstructionLanguage { ko, en, ja, zh, es, de, fr, vi, th, ar, id, ru, other }

class InstructionLanguagePolicy {
  const InstructionLanguagePolicy._();
  static final _letters = RegExp(r'[\p{L}\p{M}]', unicode: true);
  static final _latinHangul = RegExp(r'^[A-Za-z\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]$');
  static final _hangul = RegExp(r'[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]');
  static final _english = RegExp(r'\b(move|go|drive|forward|backward|back|reverse|turn|rotate|left|right|stop|halt|'
    r'status|battery|check|where|save|remember|run|execute|routine|cancel|navigation|navigate|position|'
    r'arm|gripper|open|close|raise|lower|lift|pick|grab|strafe|slide|home|usual|hello|hi|hey|thanks|thank|why|explain|who|what|tell|good)\b', caseSensitive: false);
  static final _latinHints = <InstructionLanguage, RegExp>{
    InstructionLanguage.de: RegExp(r'\b(fahr|fahre|dreh|drehe|vorwärts|rückwärts|zurück|links|rechts|wenn|bis|kamera|merke|nenne|schau)\b', caseSensitive: false),
    InstructionLanguage.fr: RegExp(r'\b(avance|recule|tourne|sinon|batterie|reviens|cuisine|droite|gauche|jusqu|quand|regarde|caméra|souviens|appelle|vois)\b', caseSensitive: false),
    InstructionLanguage.es: RegExp(r'\b(avanza|avanzar|retrocede|gira|izquierda|derecha|hasta|cuando|recuerda|llámame|mira|ves|si|detente|hazlo)\b', caseSensitive: false),
    InstructionLanguage.vi: RegExp(r'đi|thẳng|rẽ|phải|trái|lùi|rồi|nếu|đến khi|nhớ|nhìn', caseSensitive: false),
    InstructionLanguage.id: RegExp(r'\b(maju|mundur|belok|kanan|kiri|lalu|jika|sampai|ingat|lihat|panggil)\b', caseSensitive: false),
  };

  /// Ignore *known names* when choosing the language: "go to 東京" is an English instruction.
  /// Do not strip arbitrary quoted text or learned phrases, which may contain a condition.
  static String _withoutNames(String instruction, AgentManifest manifest) {
    final names = <String>{...manifest.places.map((p) => p.name), ...manifest.routines,
      ...manifest.armPoses, ...manifest.fleetRobots, ...manifest.fleetAliases.keys,
      ?manifest.persona?.name};
    var text = instruction;
    for (final name in names.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      if (name.trim().isEmpty) continue;
      if (instruction.trim().toLowerCase() == name.trim().toLowerCase()) continue;
      text = text.replaceAll(RegExp(r'(?<![\p{L}\p{N}_])' + RegExp.escape(name) + r'(?![\p{L}\p{N}_])',
        unicode: true, caseSensitive: false), ' ENTITY ');
    }
    return text;
  }

  static InstructionLanguage language(String instruction, [AgentManifest? manifest]) {
    final t = manifest == null ? instruction : _withoutNames(instruction, manifest);
    if (RegExp(r'[\u3040-\u30ff\uff66-\uff9f]').hasMatch(t)) return InstructionLanguage.ja;
    if (RegExp(r'[\u3400-\u9fff]').hasMatch(t)) return InstructionLanguage.zh;
    if (RegExp(r'[\u0400-\u052f]').hasMatch(t)) return InstructionLanguage.ru;
    if (RegExp(r'[\u0600-\u06ff]').hasMatch(t)) return InstructionLanguage.ar;
    if (RegExp(r'[\u0e00-\u0e7f]').hasMatch(t)) return InstructionLanguage.th;
    for (final hint in _latinHints.entries) {
      if (hint.value.hasMatch(t)) return hint.key;
    }
    if (_letters.allMatches(t).any((m) => !_latinHangul.hasMatch(m[0]!))) return InstructionLanguage.other;
    return _hangul.hasMatch(t) ? InstructionLanguage.ko : InstructionLanguage.en;
  }

  static const _number = r'\d+(?:\.\d+)?';
  static String _distance(String units) => '$_number\\s*(?:$units)';
  static String _angle(String units) => '$_number\\s*(?:$units)';
  static final _grammar = <RegExp, (String, String, String)>{};
  static RegExp _direct(String move, String turn, String join) {
    final whole = RegExp(
      '^(?:$move|$turn)(?:\\s*(?:$join)(?:\\s*(?:$join))?\\s*(?:$move|$turn)){0,3}' r'[.!~。！？?]*$', caseSensitive: false);
    _grammar[whole] = (move, turn, join);
    return whole;
  }
  static final _simple = <InstructionLanguage, RegExp>{
    InstructionLanguage.ja: _direct(
      '${_distance('センチ(?:メートル)?|メートル|cm|m')}\\s*(?:前に進んで|前進|下がって|後退)',
      '(?:左|右)に(?:${_angle('度|°')})?(?:回って|曲がって|回転して)', r'そして|それから|[、,;]|(?=左|右)'),
    InstructionLanguage.zh: _direct(
      '(?:向前走|前进|前進|后退|後退)\\s*${_distance('厘米|公分|米|cm|m')}',
      '(?:向)?(?:左|右)(?:转|轉)\\s*(?:${_angle('度|°')})?', r'然后|然後|再|并且|並且|[，,;]'),
    InstructionLanguage.es: _direct(
      '(?:avanza|retrocede)\\s+${_distance('centímetros|centimetros|metros|metro|cm|m')}',
      'gira\\s+(?:${_angle('grados|°')}\\s+)?a\\s+la\\s+(?:derecha|izquierda)', r'y(?:\s+luego)?|luego|después|[,;]'),
    InstructionLanguage.de: _direct(
      'fahr(?:e)?(?:\\s+dann)?\\s+${_distance('zentimeter|meter|cm|m')}\\s+(?:vorwärts|rückwärts|zurück)',
      'dreh(?:e)?(?:\\s+dich)?(?:\\s+${_angle('grad|°')})?\\s+nach\\s+(?:rechts|links)', r'und(?:\s+dann)?|dann|[,;]'),
    InstructionLanguage.fr: _direct(
      '(?:avance|recule)\\s+(?:de\\s+)?${_distance('centimètres|centimetres|mètres|metres|cm|m')}',
      'tourne\\s+[àa]\\s+(?:droite|gauche)(?:\\s+de\\s+${_angle('degrés|degres|°')})?', r'et(?:\s+puis)?|puis|[,;]'),
    InstructionLanguage.vi: _direct(
      '(?:đi\\s+thẳng|lùi\\s+lại)\\s+${_distance('cm|m|centimét|mét')}',
      'rẽ\\s+(?:phải|trái)(?:\\s+${_angle('độ|°')})?', r'rồi|và|sau đó|[,;]'),
    InstructionLanguage.th: _direct(
      '(?:เดินหน้า|ถอยหลัง)\\s*${_distance('เซนติเมตร|เมตร|cm|m')}',
      'เลี้ยว(?:ขวา|ซ้าย)(?:\\s*${_angle('องศา|°')})?', r'แล้ว|และ|จากนั้น|[,;]|(?=เลี้ยว|เดินหน้า|ถอยหลัง)'),
    InstructionLanguage.ar: _direct(
      '(?:تقدم|ارجع|تراجع)\\s+${_distance('سنتيمتر|سم|متر|cm|m')}',
      'استدر\\s+(?:يمينا|يسارا)(?:\\s+${_angle('درجة|°')})?', r'ثم|(?<=\s)و|[,;،]'),
    InstructionLanguage.id: _direct(
      '(?:maju|mundur)\\s+${_distance('sentimeter|meter|cm|m')}',
      'belok\\s+(?:kanan|kiri)(?:\\s+${_angle('derajat|°')})?', r'lalu|dan|kemudian|[,;]'),
    InstructionLanguage.ru: _direct(
      '(?:проедь|отъедь|езжай)\\s+(?:впер[её]д|назад)\\s+(?:на\\s+)?${_distance('сантиметров|сантиметра|метров|метра|см|м|cm|m')}',
      'повернись\\s+(?:направо|налево)(?:\\s+на\\s+${_angle('градусов|градуса|°')})?', r'(?<=\s)и(?=\s)|затем|потом|[,;]'),
  };

  static bool needsOnline(String instruction, AgentManifest manifest) {
    final lang = language(instruction, manifest);
    if (lang == InstructionLanguage.ko) return false;
    if (lang == InstructionLanguage.en) {
      final body = _withoutNames(instruction, manifest);
      if (_english.hasMatch(body)) return false;
      final plain = instruction.trim().toLowerCase().replaceAll(RegExp(r'[\s.,!?~]+'), '');
      if (manifest.routines.any((n) => n.toLowerCase().replaceAll(RegExp(r'[\s.,!?~]+'), '') == plain)) return false;
      if (manifest.learned.any((tool) => tool.phrases.any((p) => p.toLowerCase().replaceAll(RegExp(r'[\s.,!?~]+'), '') == plain))) return false;
    }
    return !(_simple[lang]?.hasMatch(instruction.trim()) ?? false);
  }

  static final _centimetres = RegExp(r'centi|centí|sentim|см(?![а-яё])|センチ|厘米|公分|zentimeter|сантим|เซนติ|سنتي|سم|\bcm\b', caseSensitive: false);
  static final _backward = RegExp(r'下がって|後退|后退|retrocede|zurück|rückwärts|recule|lùi|ถอยหลัง|ارجع|تراجع|mundur|назад|отъедь',
      caseSensitive: false);
  static final _rightward = RegExp(r'右|derecha|rechts|droite|phải|ขวา|يمين|kanan|направо', caseSensitive: false);

  /// The calls for a direct-motion sentence of the measured languages ("1メートル前に進んで、左に90度回って"),
  /// read by its grammar: no model, so the same sentence always gives the same calls. Null when the
  /// sentence is not one of those, or a part cannot be read: the on-device model then plans it as before.
  static List<SkillCall>? directCalls(String instruction, AgentManifest manifest) {
    final lang = language(instruction, manifest);
    final whole = _simple[lang];
    final grammar = whole == null ? null : _grammar[whole];
    if (grammar == null || !whole!.hasMatch(instruction.trim())) return null;
    final (move, turn, join) = grammar;
    final moveOnly = RegExp('^(?:$move)\$', caseSensitive: false), turnOnly = RegExp('^(?:$turn)\$', caseSensitive: false);
    final text = instruction.trim().replaceAll(RegExp(r'[.!~。！？?]+$'), '');
    final calls = <SkillCall>[];
    for (final raw in text.split(RegExp('\\s*(?:$join)(?:\\s*(?:$join))?\\s*', caseSensitive: false))) {
      final part = raw.trim();
      if (part.isEmpty) continue;
      final number = double.tryParse(RegExp(r'\d+(?:\.\d+)?').firstMatch(part)?[0] ?? '');
      if (moveOnly.hasMatch(part) && number != null && manifest.skill('move') != null) {
        final metres = _centimetres.hasMatch(part) ? number / 100 : number;
        calls.add(SkillCall('move', {'distance_m': _backward.hasMatch(part) ? -metres : metres}));
      } else if (turnOnly.hasMatch(part) && manifest.skill('rotate') != null) {
        final degrees = number ?? 90;
        calls.add(SkillCall('rotate', {'angle_deg': _rightward.hasMatch(part) ? -degrees : degrees}));
      } else {
        return null;
      }
    }
    return calls.isEmpty ? null : calls;
  }

  static String unavailable(String instruction, AgentManifest manifest) => switch (language(instruction, manifest)) {
    InstructionLanguage.ko => '이 지시는 온라인 AI의 해석이 필요해요. 지금은 이용할 수 없어서 아무 동작도 하지 않았어요.',
    InstructionLanguage.ja => 'この指示にはオンラインAIが必要です。今は利用できないため、何も実行していません。',
    InstructionLanguage.zh => '此指令需要在线 AI。目前无法使用，因此没有执行任何操作。',
    InstructionLanguage.es => 'Esta instrucción necesita la IA en línea. No está disponible, así que no se ha ejecutado ninguna acción.',
    InstructionLanguage.de => 'Diese Anweisung benötigt die Online-KI. Sie ist nicht verfügbar, daher wurde nichts ausgeführt.',
    InstructionLanguage.fr => 'Cette instruction nécessite l’IA en ligne. Elle est indisponible, donc aucune action n’a été exécutée.',
    InstructionLanguage.vi => 'Chỉ dẫn này cần AI trực tuyến. Hiện không khả dụng nên chưa thực hiện hành động nào.',
    InstructionLanguage.th => 'คำสั่งนี้ต้องใช้ AI ออนไลน์ ขณะนี้ไม่พร้อมใช้งาน จึงยังไม่ได้ดำเนินการใด ๆ',
    InstructionLanguage.ar => 'تحتاج هذه التعليمة إلى الذكاء الاصطناعي عبر الإنترنت. إنه غير متاح الآن، لذلك لم يتم تنفيذ أي إجراء.',
    InstructionLanguage.id => 'Instruksi ini memerlukan AI daring. Saat ini tidak tersedia, jadi tidak ada tindakan yang dijalankan.',
    InstructionLanguage.ru => 'Для этой инструкции нужен онлайн-ИИ. Сейчас он недоступен, поэтому никаких действий не выполнено.',
    _ => 'This instruction needs the online assistant. It is unavailable, so nothing was done.',
  };

  /// Bare affirmative stop words only. A condition or a negation must never become an emergency stop.
  static final _stop = RegExp(r'^\s*[¡¿]?\s*(?:stop|halt|e-?stop|멈춰|멈춰줘|멈춰라|정지|정지해|스톱|그만|그만해|서|섯|멈추기|'
    r'止まって(?:ください)?|停止(?:して)?|緊急停止|停|停下|停下来|急停|para|párate|alto|detente|'
    r'arrête|arrête-toi|stopp|anhalten|dừng|dừng lại|หยุด|توقف|قف|berhenti|стоп|остановись|стой|pare|pará|रुको|रुक जाओ|रुकें|停下來|停車|急停車|fermati|fermo|ferma|alt|dur|durun|durdur|arrêtez|stoppe|stoj|stój|zatrzymaj się|deténganse|deteneos|párense|paren|fermatevi|fermiamoci|parem|arrêtez-vous|haltet an|stoppt|остановитесь|стойте|止まれ|停下来吧|durun)'
    r'\s*[.!~。！?？]*\s*$', caseSensitive: false);
  static bool isStopWord(String instruction) => _stop.hasMatch(instruction);
}
