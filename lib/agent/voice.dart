import 'instruction_language.dart';
import 'skill.dart';

/// What the assistant says, made by the app instead of the on-device model.
///
/// A 2B model picks the right skills (12/12 on the everyday requests, 35/36 across 12 languages) but
/// its sentences follow its examples: Korean answers to English questions, translated names, now and
/// then a wrong figure. So it only plans; the sentence the person reads is built here from the calls
/// and the real results, in the language of their request. A bigger cloud model writes its own replies.

/// The app's screen languages, then the other languages the on-device model takes direct motion in
/// (see [InstructionLanguagePolicy]): for those, only motion sentences are written in the language.
enum ReplyLanguage { ko, en, ja, zh, es, de, fr, vi, th, id, ru, ar }

final _hangul = RegExp(r'[ㄱ-ㆎ가-힣]');
bool hasHangul(String text) => _hangul.hasMatch(text);

final _kana = RegExp(r'[\u3040-\u30ff]');
final _han = RegExp(r'[\u4e00-\u9fff]');
final _spanish = RegExp(r'\b(avanza|avanzar|retrocede|gira|girar|izquierda|derecha|detente|vuelve|metros?|grados|centímetros)\b|[ñáéíóú¿¡]',
    caseSensitive: false);

/// The language to answer in, from the request's own script and words: Korean, Japanese (kana), Chinese
/// (Han without kana), Spanish, else English. The same languages as the app's screens.
ReplyLanguage replyLanguageFor(String instruction) {
  if (hasHangul(instruction)) return ReplyLanguage.ko;
  if (_kana.hasMatch(instruction)) return ReplyLanguage.ja;
  if (_han.hasMatch(instruction)) return ReplyLanguage.zh;
  // Vietnamese and French words carry accents too: their own words decide before Spanish accents do.
  final other = InstructionLanguagePolicy.language(instruction);
  if (other == InstructionLanguage.vi) return ReplyLanguage.vi;
  if (other == InstructionLanguage.fr) return ReplyLanguage.fr;
  if (_spanish.hasMatch(instruction)) return ReplyLanguage.es;
  return switch (other) {
    InstructionLanguage.de => ReplyLanguage.de, InstructionLanguage.fr => ReplyLanguage.fr,
    InstructionLanguage.vi => ReplyLanguage.vi, InstructionLanguage.th => ReplyLanguage.th,
    InstructionLanguage.id => ReplyLanguage.id, InstructionLanguage.ru => ReplyLanguage.ru,
    InstructionLanguage.ar => ReplyLanguage.ar, _ => ReplyLanguage.en,
  };
}

/// Motion sentences for the languages beyond the screens': (text, joiner between steps). Anything else
/// is said in English words.
String? _motion(SkillCall c, ReplyLanguage lang) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  final d = _n(v('distance_m').abs()), deg = _n(v('angle_deg').abs());
  final back = v('distance_m') < 0, rightSide = v('distance_m') < 0, rightTurn = v('angle_deg') < 0;
  final name = '${a['name']}';
  return switch ((lang, c.name)) {
    (ReplyLanguage.de, 'move') => back ? 'fahre $d m zurück' : 'fahre $d m vorwärts',
    (ReplyLanguage.de, 'strafe') => 'fahre $d m seitlich nach ${rightSide ? 'rechts' : 'links'}',
    (ReplyLanguage.de, 'rotate') => 'drehe mich $deg° nach ${rightTurn ? 'rechts' : 'links'}',
    (ReplyLanguage.de, 'go_to_place') => 'fahre zu $name',
    (ReplyLanguage.de, 'stop') => 'halte an',
    (ReplyLanguage.fr, 'move') => back ? 'je recule de $d m' : 'j’avance de $d m',
    (ReplyLanguage.fr, 'strafe') => 'je me décale de $d m à ${rightSide ? 'droite' : 'gauche'}',
    (ReplyLanguage.fr, 'rotate') => 'je tourne de $deg° à ${rightTurn ? 'droite' : 'gauche'}',
    (ReplyLanguage.fr, 'go_to_place') => 'je vais à $name',
    (ReplyLanguage.fr, 'stop') => 'je m’arrête',
    (ReplyLanguage.vi, 'move') => back ? 'lùi $d m' : 'đi thẳng $d m',
    (ReplyLanguage.vi, 'strafe') => 'đi ngang sang ${rightSide ? 'phải' : 'trái'} $d m',
    (ReplyLanguage.vi, 'rotate') => 'rẽ ${rightTurn ? 'phải' : 'trái'} $deg°',
    (ReplyLanguage.vi, 'go_to_place') => 'đi đến $name',
    (ReplyLanguage.vi, 'stop') => 'dừng lại',
    (ReplyLanguage.th, 'move') => back ? 'ถอยหลัง $d เมตร' : 'เดินหน้า $d เมตร',
    (ReplyLanguage.th, 'strafe') => 'เลื่อนไปทาง${rightSide ? 'ขวา' : 'ซ้าย'} $d เมตร',
    (ReplyLanguage.th, 'rotate') => 'เลี้ยว${rightTurn ? 'ขวา' : 'ซ้าย'} $deg องศา',
    (ReplyLanguage.th, 'go_to_place') => 'ไปที่ $name',
    (ReplyLanguage.th, 'stop') => 'หยุด',
    (ReplyLanguage.id, 'move') => back ? 'mundur $d m' : 'maju $d m',
    (ReplyLanguage.id, 'strafe') => 'geser ke ${rightSide ? 'kanan' : 'kiri'} $d m',
    (ReplyLanguage.id, 'rotate') => 'belok ${rightTurn ? 'kanan' : 'kiri'} $deg°',
    (ReplyLanguage.id, 'go_to_place') => 'pergi ke $name',
    (ReplyLanguage.id, 'stop') => 'berhenti',
    (ReplyLanguage.ru, 'move') => back ? 'еду назад на $d м' : 'еду вперёд на $d м',
    (ReplyLanguage.ru, 'strafe') => 'смещаюсь ${rightSide ? 'вправо' : 'влево'} на $d м',
    (ReplyLanguage.ru, 'rotate') => 'поворачиваю ${rightTurn ? 'направо' : 'налево'} на $deg°',
    (ReplyLanguage.ru, 'go_to_place') => 'еду к точке «$name»',
    (ReplyLanguage.ru, 'stop') => 'останавливаюсь',
    (ReplyLanguage.ar, 'move') => back ? 'أرجع $d م' : 'أتقدم $d م',
    (ReplyLanguage.ar, 'strafe') => 'أتحرك جانبًا ${rightSide ? 'لليمين' : 'لليسار'} $d م',
    (ReplyLanguage.ar, 'rotate') => 'أستدير ${rightTurn ? 'يمينًا' : 'يسارًا'} $deg°',
    (ReplyLanguage.ar, 'go_to_place') => 'أذهب إلى $name',
    (ReplyLanguage.ar, 'stop') => 'أتوقف',
    // Remembering, said back in the same languages (the name as given).
    (_, 'update_profile') when a['field'] == 'call_person' => switch (lang) {
      ReplyLanguage.de => 'nenne dich ab jetzt ${a['value']}', ReplyLanguage.fr => 'je t’appellerai ${a['value']}',
      ReplyLanguage.vi => 'từ giờ gọi bạn là ${a['value']}', ReplyLanguage.th => 'ต่อจากนี้จะเรียกคุณว่า ${a['value']}',
      ReplyLanguage.id => 'mulai sekarang memanggilmu ${a['value']}', ReplyLanguage.ru => 'теперь буду звать тебя ${a['value']}',
      ReplyLanguage.ar => 'سأناديك ${a['value']} من الآن', _ => null,
    },
    (_, 'remember') => switch (lang) {
      ReplyLanguage.de => 'merke es mir', ReplyLanguage.fr => 'je m’en souviendrai', ReplyLanguage.vi => 'sẽ ghi nhớ điều đó',
      ReplyLanguage.th => 'จะจำไว้', ReplyLanguage.id => 'akan mengingatnya', ReplyLanguage.ru => 'запомню это',
      ReplyLanguage.ar => 'سأتذكر ذلك', _ => null,
    },
    _ => null,
  };
}

const _then = {
  ReplyLanguage.de: ', dann ', ReplyLanguage.fr: ', puis ', ReplyLanguage.vi: ', rồi ', ReplyLanguage.th: ' แล้ว',
  ReplyLanguage.id: ', lalu ', ReplyLanguage.ru: ', затем ', ReplyLanguage.ar: ' ثم ',
};

String _n(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v') ?? 0;
  return d == d.roundToDouble() ? '${d.toInt()}' : '${(d * 100).round() / 100}';
}

/// Korean particle after [word]: (with final consonant, without), e.g. ('으로', '로'), ('을', '를').
String _josa(String word, String withBatchim, String without) {
  if (word.isEmpty) return without;
  final c = word.codeUnitAt(word.length - 1);
  if (c < 0xAC00 || c > 0xD7A3) return '$withBatchim/$without'.contains('로') ? '(으)로' : '$withBatchim($without)';
  final batchim = (c - 0xAC00) % 28;
  // "로": no 으 after ㄹ either.
  if (withBatchim == '으로' && batchim == 8) return without;
  return batchim == 0 ? without : withBatchim;
}

/// What the calls will do: "Turning left 90°, then driving forward 0.5 m." / "왼쪽으로 90° 돌고, 앞으로 0.5 m 갈게요."
String planSentence(List<SkillCall> calls, ReplyLanguage lang) {
  if (calls.isEmpty) return '';
  // Japanese, Chinese, Spanish: the common skills in the language, anything else in English words.
  if (lang == ReplyLanguage.ja) return '${calls.map((c) => _ja(c) ?? _en(c)).join('し、')}します。';
  if (lang == ReplyLanguage.zh) return '我将${calls.map((c) => _zh(c) ?? _en(c)).join('，然后')}。';
  if (lang == ReplyLanguage.es) {
    final text = calls.map((c) => _es(c) ?? _en(c)).join(' y luego ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }
  if (lang == ReplyLanguage.en) {
    final text = calls.map(_en).join(', then ');
    return '${text[0].toUpperCase()}${text.substring(1)}.';
  }
  if (_then.containsKey(lang)) {
    final text = calls.map((c) => _motion(c, lang) ?? _en(c)).join(_then[lang]!);
    final sentence = '${text[0].toUpperCase()}${text.substring(1)}';
    return lang == ReplyLanguage.th ? sentence : '$sentence.';
  }
  final parts = [for (final c in calls) _ko(c)];
  return [for (var i = 0; i < parts.length; i++) i == parts.length - 1 ? parts[i].$2 : parts[i].$1].join(', ');
}

String _en(SkillCall c) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  return switch (c.name) {
    'move' => v('distance_m') < 0 ? 'driving backward ${_n(v('distance_m').abs())} m' : 'driving forward ${_n(v('distance_m'))} m',
    'strafe' => 'sliding ${v('distance_m') < 0 ? 'right' : 'left'} ${_n(v('distance_m').abs())} m',
    'rotate' => 'turning ${v('angle_deg') < 0 ? 'right' : 'left'} ${_n(v('angle_deg').abs())}°',
    'go_to_place' => 'going to ${a['name']}',
    'navigate_to' => 'going to (${_n(a['x'])}, ${_n(a['y'])})',
    'cancel_navigation' => 'cancelling navigation',
    'get_status' => 'checking what it is doing',
    'check_robot' => 'checking the robot',
    'find_position' => 'finding its position on the map',
    'save_place' => 'saving this spot as ${a['name']}',
    'save_map' => 'saving the map',
    'run_routine' => 'running ${a['name']}',
    'save_routine' => 'saving that as the routine ${a['name']}',
    'look' => 'looking through the camera',
    'arm_to_pose' => 'moving the arm to ${a['name']}',
    'update_profile' => a['field'] == 'call_person' ? 'calling you ${a['value']} from now on'
        : 'remembering that my ${'${a['field']}'.replaceFirst('robot_', '')} is ${a['value']}',
    'remember' => 'keeping that in mind',
    'learn_phrase' => 'remembering that "${a['phrase']}" means ${a['meaning']}',
    'gripper' => a['action'] == 'open' ? 'opening the gripper' : 'closing the gripper',
    'stop' => 'stopping',
    final n when n.startsWith('my_usual_') => 'doing the usual',
    final n when n.startsWith('my_') => 'using ${n.substring(3).replaceAll('_', ' ')}',
    _ => c.name.replaceAll('_', ' '),
  };
}

String? _ja(SkillCall c) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  return switch (c.name) {
    'move' => v('distance_m') < 0 ? '${_n(v('distance_m').abs())} m 後退' : '${_n(v('distance_m'))} m 前進',
    'strafe' => '${v('distance_m') < 0 ? '右' : '左'}に${_n(v('distance_m').abs())} m 横移動',
    'rotate' => '${v('angle_deg') < 0 ? '右' : '左'}に${_n(v('angle_deg').abs())}°回転',
    'go_to_place' => '${a['name']}へ移動',
    'navigate_to' => '(${_n(a['x'])}, ${_n(a['y'])})へ移動',
    'cancel_navigation' => '移動をキャンセル',
    'get_status' => '状態を確認',
    'check_robot' => 'ロボットを点検',
    'run_routine' => '${a['name']}を実行',
    'arm_to_pose' => 'アームを${a['name']}の姿勢に移動',
    'gripper' => a['action'] == 'open' ? 'グリッパーをオープン' : 'グリッパーをクローズ',
    'stop' => '停止',
    'update_profile' => a['field'] == 'call_person' ? 'これから${a['value']}とお呼び' : '${a['value']}を記憶',
    'remember' => 'そのことを記憶',
    final n when n.startsWith('my_usual_') => 'いつもの動作を実行',
    _ => null,
  };
}

String? _zh(SkillCall c) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  return switch (c.name) {
    'move' => v('distance_m') < 0 ? '后退 ${_n(v('distance_m').abs())} 米' : '前进 ${_n(v('distance_m'))} 米',
    'strafe' => '向${v('distance_m') < 0 ? '右' : '左'}平移 ${_n(v('distance_m').abs())} 米',
    'rotate' => '向${v('angle_deg') < 0 ? '右' : '左'}转 ${_n(v('angle_deg').abs())}°',
    'go_to_place' => '前往${a['name']}',
    'navigate_to' => '前往 (${_n(a['x'])}, ${_n(a['y'])})',
    'cancel_navigation' => '取消导航',
    'get_status' => '查看当前状态',
    'check_robot' => '检查机器人',
    'run_routine' => '运行${a['name']}',
    'arm_to_pose' => '把机械臂移到${a['name']}姿态',
    'gripper' => a['action'] == 'open' ? '打开夹爪' : '合上夹爪',
    'stop' => '停止',
    'update_profile' => a['field'] == 'call_person' ? '以后称呼你为${a['value']}' : '记住${a['value']}',
    'remember' => '记住这一点',
    final n when n.startsWith('my_usual_') => '照常执行',
    _ => null,
  };
}

String? _es(SkillCall c) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  return switch (c.name) {
    'move' => v('distance_m') < 0 ? 'retrocedo ${_n(v('distance_m').abs())} m' : 'avanzo ${_n(v('distance_m'))} m',
    'strafe' => 'me desplazo ${_n(v('distance_m').abs())} m a la ${v('distance_m') < 0 ? 'derecha' : 'izquierda'}',
    'rotate' => 'giro ${_n(v('angle_deg').abs())}° a la ${v('angle_deg') < 0 ? 'derecha' : 'izquierda'}',
    'go_to_place' => 'voy a ${a['name']}',
    'navigate_to' => 'voy a (${_n(a['x'])}, ${_n(a['y'])})',
    'cancel_navigation' => 'cancelo la navegación',
    'get_status' => 'reviso qué estoy haciendo',
    'check_robot' => 'reviso el robot',
    'run_routine' => 'ejecuto ${a['name']}',
    'arm_to_pose' => 'muevo el brazo a ${a['name']}',
    'gripper' => a['action'] == 'open' ? 'abro la pinza' : 'cierro la pinza',
    'stop' => 'me detengo',
    'update_profile' => a['field'] == 'call_person' ? 'a partir de ahora te llamo ${a['value']}' : 'recuerdo ${a['value']}',
    'remember' => 'lo tengo en cuenta',
    final n when n.startsWith('my_usual_') => 'hago lo de siempre',
    _ => null,
  };
}

/// (clause before another, clause at the end).
(String, String) _ko(SkillCall c) {
  final a = c.args;
  double v(String k) => (a[k] as num? ?? 0).toDouble();
  String name() => '${a['name']}';
  return switch (c.name) {
    'move' => v('distance_m') < 0
        ? ('뒤로 ${_n(v('distance_m').abs())} m 가고', '뒤로 ${_n(v('distance_m').abs())} m 갈게요.')
        : ('앞으로 ${_n(v('distance_m'))} m 가고', '앞으로 ${_n(v('distance_m'))} m 갈게요.'),
    'strafe' => ('${v('distance_m') < 0 ? '오른쪽' : '왼쪽'}으로 ${_n(v('distance_m').abs())} m 옆으로 가고',
        '${v('distance_m') < 0 ? '오른쪽' : '왼쪽'}으로 ${_n(v('distance_m').abs())} m 옆으로 갈게요.'),
    'rotate' => ('${v('angle_deg') < 0 ? '오른쪽' : '왼쪽'}으로 ${_n(v('angle_deg').abs())}° 돌고',
        '${v('angle_deg') < 0 ? '오른쪽' : '왼쪽'}으로 ${_n(v('angle_deg').abs())}° 돌게요.'),
    'go_to_place' => ('${name()}${_josa(name(), '으로', '로')} 가고', '${name()}${_josa(name(), '으로', '로')} 갈게요.'),
    'navigate_to' => ('(${_n(a['x'])}, ${_n(a['y'])})로 가고', '(${_n(a['x'])}, ${_n(a['y'])})로 갈게요.'),
    'cancel_navigation' => ('이동을 취소하고', '이동을 취소할게요.'),
    'get_status' => ('지금 상태를 확인하고', '지금 상태를 확인할게요.'),
    'check_robot' => ('로봇 상태를 확인하고', '로봇 상태를 확인할게요.'),
    'find_position' => ('지도와 맞춰 위치를 찾고', '지도와 맞춰 위치를 찾을게요.'),
    'save_place' => ('여기를 ${name()}${_josa(name(), '으로', '로')} 저장하고', '여기를 ${name()}${_josa(name(), '으로', '로')} 저장할게요.'),
    'save_map' => ('지도를 저장하고', '지도를 저장할게요.'),
    'run_routine' => ('${name()}${_josa(name(), '을', '를')} 실행하고', '${name()}${_josa(name(), '을', '를')} 실행할게요.'),
    'save_routine' => ('방금 한 동작을 ${name()}${_josa(name(), '으로', '로')} 저장하고',
        '방금 한 동작을 ${name()}${_josa(name(), '으로', '로')} 저장할게요.'),
    'look' => ('카메라로 보고', '카메라로 볼게요.'),
    'arm_to_pose' => ('팔을 ${name()} 자세로 움직이고', '팔을 ${name()} 자세로 움직일게요.'),
    'update_profile' => switch (a['field']) {
      'call_person' => ('앞으로 ${a['value']}${_josa('${a['value']}', '이라고', '라고')} 부르고',
          '앞으로 ${a['value']}${_josa('${a['value']}', '이라고', '라고')} 부를게요.'),
      'robot_name' => ('제 이름을 ${a['value']}${_josa('${a['value']}', '으로', '로')} 하고',
          '좋아요, 제 이름은 이제 ${a['value']}${_josa('${a['value']}', '이에요', '예요')}.'),
      _ => ('기억하고', '기억해 둘게요.'),
    },
    'remember' => ('기억해 두고', '기억해 둘게요.'),
    'learn_phrase' => ('"${a['phrase']}"의 뜻을 기억하고', '알겠어요. "${a['phrase']}"${_josa('${a['phrase']}', '은', '는')} ${a['meaning']}라는 뜻으로 기억할게요.'),
    'gripper' => a['action'] == 'open' ? ('그리퍼를 열고', '그리퍼를 열게요.') : ('그리퍼를 닫고', '그리퍼를 닫을게요.'),
    'stop' => ('멈추고', '멈출게요.'),
    final n when n.startsWith('my_usual_') => ('평소처럼 하고', '평소처럼 할게요.'),
    final n when n.startsWith('my_') => ('${n.substring(3)} 하고', '${n.substring(3)} 할게요.'),
    _ => ('${c.name} 하고', '${c.name} 할게요.'),
  };
}

/// The answer to a question skill (get_status, check_robot), from its result data: exact figures, no model.
String? reportSentence(SkillCall call, SkillResult r, ReplyLanguage lang) {
  final d = r.data;
  if (!r.ok) return lang == ReplyLanguage.ko ? '확인하지 못했어요: ${r.message}' : r.message;
  switch (call.name) {
    case 'check_robot':
      if (lang != ReplyLanguage.ko) return r.message;
      final parts = <String>[];
      final battery = d['battery'];
      parts.add(battery == null ? '이 로봇은 배터리 정보를 보내지 않아요.'
          : '배터리는 $battery예요${d['battery_warning'] == null ? '' : ' (낮아요)'}.');
      final errors = (d['errors'] as List?) ?? const [], warnings = (d['warnings'] as List?) ?? const [];
      if (errors.isEmpty && warnings.isEmpty) {
        parts.add('최근 10분 동안 경고나 오류는 없어요.');
      } else {
        parts.add('최근 10분 동안 오류 ${errors.length}개, 경고 ${warnings.length}개가 있어요'
            '${errors.isNotEmpty ? '. 최근 오류: ${errors.first}' : warnings.isNotEmpty ? '. 최근 경고: ${warnings.first}' : ''}.');
      }
      return parts.join(' ');
    case 'get_status':
      if (lang != ReplyLanguage.ko) return r.message;
      final moving = d['motion'] != null && d['motion'] != 'stopped';
      final nav = '${d['navigation'] ?? 'idle'}';
      final left = d['distance_remaining_m'];
      final navText = switch (nav) {
        'active' => '목적지로 가는 중이에요${left == null ? '' : ' (${_n(left)} m 남음)'}',
        'idle' => '이동 목표는 없어요',
        'succeeded' => '마지막 이동은 도착했어요',
        'canceled' => '마지막 이동은 취소됐어요',
        _ => '마지막 이동은 실패했어요',
      };
      return '${moving ? '움직이는 중이고' : '멈춰 있고'}, $navText.';
  }
  return null;
}

/// Short fixed sentences the app says itself.
String askName(ReplyLanguage lang) => lang == ReplyLanguage.ko
    ? '어떤 이름으로 저장할까요? 예: "여기를 부엌으로 저장해"'
    : 'What name should it have? For example: save this spot as "kitchen".';

String cannotDo(ReplyLanguage lang) => switch (lang) {
  ReplyLanguage.ko => '그건 이 로봇이 할 수 없어요.',
  ReplyLanguage.ja => 'このロボットにはそれはできません。',
  ReplyLanguage.zh => '这个机器人做不到。',
  ReplyLanguage.es => 'Este robot no puede hacer eso.',
  _ => 'This robot cannot do that.',
};

/// [missingAbility]'s reasons in the person's language.
String lacking(String reason, ReplyLanguage lang) {
  if (lang == ReplyLanguage.en) return reason;
  if (lang != ReplyLanguage.ko) {
    const ja = {'This robot cannot move sideways.': 'このロボットは横に動けません。',
      'This robot cannot turn in place.': 'このロボットはその場で回転できません。',
      'This robot has no map navigation.': 'このロボットは地図で移動できません。'};
    const zh = {'This robot cannot move sideways.': '这个机器人不能横向移动。',
      'This robot cannot turn in place.': '这个机器人不能原地转向。',
      'This robot has no map navigation.': '这个机器人不能按地图导航。'};
    const es = {'This robot cannot move sideways.': 'Este robot no puede moverse de lado.',
      'This robot cannot turn in place.': 'Este robot no puede girar sobre sí mismo.',
      'This robot has no map navigation.': 'Este robot no tiene navegación por mapa.'};
    return (switch (lang) { ReplyLanguage.ja => ja, ReplyLanguage.zh => zh, ReplyLanguage.es => es, _ => const {} })[reason] ?? reason;
  }
  return switch (reason) {
    'This robot cannot move sideways.' => '이 로봇은 옆으로 움직일 수 없어요.',
    'This robot cannot turn in place.' => '이 로봇은 제자리에서 돌 수 없어요.',
    'This robot has no map navigation.' => '이 로봇은 지도로 이동할 수 없어요.',
    _ => reason,
  };
}
