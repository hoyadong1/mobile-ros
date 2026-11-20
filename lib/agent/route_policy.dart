import 'manifest.dart';
import 'instruction_language.dart';

/// Who should handle an instruction. The rule in one place, so it can be read, tested and explained:
///
/// The on-device model (small, offline, private) does **direct robot commands**: moving, turning,
/// stopping, going to a place or a point, running or saving a routine, the arm, status and battery
/// questions, and remembering what the person tells it (that last part by fixed patterns, not the model).
///
/// The online model does what needs **seeing, judging or talking**: anything with the camera, steps that
/// depend on what happens ("if", "until", "when you see"), finding or searching, explaining or chatting,
/// and long multi-part requests. Without the online model these are refused in words; nothing moves.
enum Handler { local, cloud }

class RouteDecision {
  const RouteDecision(this.handler, this.reason);
  final Handler handler;
  /// Why, for the person ("needs the camera") and for tests.
  final String reason;
  @override
  String toString() => '${handler.name}: $reason';
}

class RoutePolicy {
  const RoutePolicy._();

  static final _camera = RegExp(r'보여|보이|봐줘|봐 줘|살펴|카메라|사진|찍어|무엇이 있|뭐가 있|뭐 있|어떻게 생겼|무슨 색|'
      r'\bsee\b|\blook\b|camera|picture|photo|what.?s (in front|around|there)|what colou?r', caseSensitive: false);
  // "가면 돼" (that will do) is not a condition.
  static final _conditional = RegExp(r'(하|이|되|있|없|오|가|보이)면\s(?!돼|된다|되지|좋겠)|때까지|동안|만약|경우에|'
      r'\bif\b|\bunless\b|\buntil\b|\bwhen(ever)?\b|\bwhile\b|\bas soon as\b', caseSensitive: false);
  static final _search = RegExp(r'찾아|찾으|따라가|따라와|쫓아|탐색해|둘러보|\bfind\b|\bsearch\b|\bfollow\b|\bexplore\b|\blook for\b',
      caseSensitive: false);
  static final _talk = RegExp(r'^(안녕|하이|헬로|고마워|감사|잘했어|기분|심심|넌 누구|너는 누구|뭐 할 수|무엇을 할 수|왜|어떻게 생각|'
      r'설명해|알려줘\s*(왜|어떻게)|이야기|얘기)|\?$|^(hi|hello|hey|thanks|thank you|good job|who are you|why|how do you|'
      r'tell me (about|why)|explain)\b', caseSensitive: false);
  /// Asking for a new tool, function or shortcut to be made: the online model defines it (define_tool).
  static final _defineTool = RegExp(r'도구|함수|단축\s*기능|기능으로\s*만들|\btool\b|\bfunction\b|\bshortcut\b', caseSensitive: false);
  /// Words for moving the robot (with a question mark, still a command).
  static final _command = RegExp(r'가\s*줄|가\s*줘|갈\s*수|와\s*줄|와\s*줘|돌아|돌\s*수|돌래|멈춰|멈출|서\s*줄|이동|회전|움직|후진|전진|'
      r'(앞|뒤|왼쪽|오른쪽)으로|\b(go|move|turn|drive|stop|rotate|come|back up)\b', caseSensitive: false);
  static final _why = RegExp(r'^(왜|how come|why)', caseSensitive: false);
  /// Questions the robot answers from its own state (the small model may take these).
  static final _stateQuestion = RegExp(r'상태|배터리|어디야|어디 있|뭐 하고|위치|에러|오류|문제|고장|'
      r'\bstatus\b|\bbattery\b|where are you|what are you doing|\berror|\bwrong\b', caseSensitive: false);
  /// More separate parts than the small model plans reliably.
  static const maxLocalParts = 4;
  static final _partBreaks = RegExp(r',|그리고|그 ?다음|다음에|then|and then|;|고\s', caseSensitive: false);

  /// Where [instruction] should go, given what the robot can do ([m]).
  static RouteDecision decide(String instruction, AgentManifest m) {
    final t = instruction.trim();
    if (m.skill('look') != null && _camera.hasMatch(t)) return const RouteDecision(Handler.cloud, 'needs the camera');
    if (_conditional.hasMatch(t)) return const RouteDecision(Handler.cloud, 'depends on what happens');
    if (_search.hasMatch(t)) return const RouteDecision(Handler.cloud, 'needs searching or following');
    if (_defineTool.hasMatch(t)) return const RouteDecision(Handler.cloud, 'making or using a tool');
    // A polite command asked as a question ("앞으로 가 줄래?", "can you turn left?") is still a command.
    final politeCommand = t.endsWith('?') && _command.hasMatch(t) && !_why.hasMatch(t);
    if (_talk.hasMatch(t) && !_stateQuestion.hasMatch(t) && !politeCommand) {
      return const RouteDecision(Handler.cloud, 'conversation, not a robot command');
    }
    if (_partBreaks.allMatches(t).length + 1 > maxLocalParts) {
      return const RouteDecision(Handler.cloud, 'too many steps for the on-device model');
    }
    if (InstructionLanguagePolicy.needsOnline(t, m)) {
      return const RouteDecision(Handler.cloud, 'needs language-aware interpretation');
    }
    return const RouteDecision(Handler.local, 'a direct robot command');
  }
}
