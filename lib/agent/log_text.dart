import '../l10n/generated/app_localizations.dart';
import 'audit_log.dart';
import 'skill.dart';
import 'skill_labels.dart';

/// The assistant's history in the app's language. Steps and results are recorded in English (the model
/// reads them, and saved history stays readable whatever the language); the common ones are shown
/// translated, and anything else as it was recorded.
String logLineIn(AuditKind kind, String text, AppLocalizations s) {
  if (s.localeName == 'en') return text;
  return switch (kind) {
    AuditKind.call => _call(text, s) ?? text,
    AuditKind.instruction || AuditKind.note || AuditKind.result => _sentence(text, s) ?? text,
    _ => text,
  };
}

final _callPattern = RegExp(r'^(\w+)\((.*?)\)( \(.*\))?$');

/// `move(distance_m: 0.2, speed: slow)` → "앞뒤로 이동 · 0.2 m · 느림".
String? _call(String text, AppLocalizations s) {
  final m = _callPattern.firstMatch(text);
  if (m == null) return null;
  final args = <String, Object?>{};
  final inner = m[2]!;
  if (inner.isNotEmpty) {
    for (final part in inner.split(', ')) {
      final i = part.indexOf(': ');
      if (i < 0) return null;
      final value = part.substring(i + 2);
      args[part.substring(0, i)] = num.tryParse(value) ?? value;
    }
  }
  return '${describeCall(SkillCall(m[1]!, args), s)}${m[3] ?? ''}';
}

String _direction(String english, AppLocalizations s) => switch (english) {
  'forward' => s.logDirForward,
  'backward' => s.logDirBackward,
  'left' => s.logDirLeft,
  'right' => s.logDirRight,
  _ => english,
};

final _patterns = <(RegExp, String Function(RegExpMatch, AppLocalizations))>[
  (RegExp(r'^Stopped\.$'), (m, s) => s.logStopped),
  (RegExp(r'^Moved ([\d.]+) m (forward|backward|left|right)\.$'),
      (m, s) => s.logMoved(_direction(m[2]!, s), m[1]!)),
  (RegExp(r'^Moved about ([\d.]+) m (forward|backward|left|right) \(estimated from time; no odometry\)\.$'),
      (m, s) => s.logMovedEstimated(_direction(m[2]!, s), m[1]!)),
  (RegExp(r'^Turned ([\d.]+)° (left|right)\.$'), (m, s) => s.logTurned(_direction(m[2]!, s), m[1]!)),
  (RegExp(r'^Turned about ([\d.]+)° (left|right) \(estimated from time; no odometry\)\.$'),
      (m, s) => s.logTurnedEstimated(_direction(m[2]!, s), m[1]!)),
  (RegExp(r'^Stopped after ([\d.]+) m of ([\d.]+) m: the robot did not get there in time \(blocked or slipping\?\)\.$'),
      (m, s) => s.logStoppedShortDistance(m[1]!, m[2]!)),
  (RegExp(r'^Stopped after ([\d.]+)° of ([\d.]+)°: the robot did not turn far enough in time\.$'),
      (m, s) => s.logStoppedShortAngle(m[1]!, m[2]!)),
  (RegExp(r'^Arrived at (.+)\.$'), (m, s) => s.logArrived(m[1]!)),
  (RegExp(r'^Navigation canceled\.$'), (m, s) => s.logNavCanceled),
  (RegExp(r'^No navigation goal was running\.$'), (m, s) => s.logNoNavGoal),
  (RegExp(r'^Nothing to do: (distance|angle) is 0\.$'), (m, s) => s.logNothingToDo),
  (RegExp(r'^Run routine "(.+)" until stopped$'), (m, s) => s.logRunRoutineUntilStopped(m[1]!)),
  (RegExp(r'^Run routine "(.+)" (\d+) times$'), (m, s) => s.logRunRoutineTimes(m[1]!, int.parse(m[2]!))),
  (RegExp(r'^Run routine "(.+)"$'), (m, s) => s.logRunRoutine(m[1]!)),
  (RegExp(r'^Routine "(.+)": (\d+) steps\.$'), (m, s) => s.logRoutineSteps(m[1]!, int.parse(m[2]!))),
];

String? _sentence(String text, AppLocalizations s) {
  for (final (pattern, build) in _patterns) {
    final m = pattern.firstMatch(text);
    if (m != null) return build(m, s);
  }
  return null;
}
