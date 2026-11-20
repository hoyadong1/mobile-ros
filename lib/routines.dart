import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent/skill.dart';
import 'app_language.dart';
import 'l10n/generated/app_localizations.dart';

/// One step of a routine: a skill call, or another routine run in its place (by id, so renaming a
/// routine keeps the references).
class RoutineStep {
  const RoutineStep.call(SkillCall this.call) : routineId = null;
  const RoutineStep.routine(String this.routineId) : call = null;

  final SkillCall? call;
  final String? routineId;

  Map<String, Object?> toJson() => call != null ? call!.toJson() : {'routine': routineId};

  static RoutineStep? fromJson(Object? json) {
    if (json is! Map) return null;
    final ref = json['routine'];
    if (ref is String && ref.isNotEmpty) return RoutineStep.routine(ref);
    final call = SkillCall.fromJson(json);
    return call == null ? null : RoutineStep.call(SkillCall(call.name, call.args));
  }
}

/// When a routine runs by itself: at [hour]:[minute] on [weekdays] (DateTime.monday .. sunday).
class RoutineSchedule {
  const RoutineSchedule({required this.hour, required this.minute, this.weekdays = const {1, 2, 3, 4, 5, 6, 7},
      this.enabled = true});

  final int hour, minute;
  final Set<int> weekdays;
  final bool enabled;

  RoutineSchedule copyWith({int? hour, int? minute, Set<int>? weekdays, bool? enabled}) => RoutineSchedule(
      hour: hour ?? this.hour, minute: minute ?? this.minute, weekdays: weekdays ?? this.weekdays,
      enabled: enabled ?? this.enabled);

  /// Whether it is due in the minute of [now].
  bool dueAt(DateTime now) =>
      enabled && weekdays.contains(now.weekday) && now.hour == hour && now.minute == minute;

  /// The next time it runs after [now], or null if it never does.
  DateTime? nextAfter(DateTime now) {
    if (!enabled || weekdays.isEmpty) return null;
    for (var day = 0; day <= 7; day++) {
      final d = DateTime(now.year, now.month, now.day + day, hour, minute);
      if (d.isAfter(now) && weekdays.contains(d.weekday)) return d;
    }
    return null;
  }

  String get label => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  Map<String, Object?> toJson() =>
      {'hour': hour, 'minute': minute, 'weekdays': (weekdays.toList()..sort()), 'enabled': enabled};

  static RoutineSchedule? fromJson(Object? json) {
    if (json is! Map) return null;
    final h = json['hour'], m = json['minute'], days = json['weekdays'];
    if (h is! int || m is! int || h < 0 || h > 23 || m < 0 || m > 59) return null;
    return RoutineSchedule(hour: h, minute: m, enabled: json['enabled'] != false,
        weekdays: days is List ? {for (final d in days) if (d is int && d >= 1 && d <= 7) d} : const {1, 2, 3, 4, 5, 6, 7});
  }
}

/// A saved sequence of robot actions ("순찰", "충전하러 가기"). Stored as data, not code: every step goes
/// through the agent's validator when it runs, so a routine can do nothing a single instruction could not.
class Routine {
  const Routine({required this.id, required this.name, required this.steps, this.schedules = const [],
    this.repeat = 1, this.pauseSeconds = 0});

  final String id;
  final String name;
  final List<RoutineStep> steps;
  final List<RoutineSchedule> schedules;
  /// How many rounds a run does: 1 = once, 0 = until stopped. Scheduled runs repeat the same way.
  final int repeat;
  /// Wait between rounds.
  final int pauseSeconds;

  static const maxRepeat = 999;

  Routine copyWith({String? name, List<RoutineStep>? steps, List<RoutineSchedule>? schedules, int? repeat,
      int? pauseSeconds}) =>
      Routine(id: id, name: name ?? this.name, steps: steps ?? this.steps, schedules: schedules ?? this.schedules,
          repeat: repeat ?? this.repeat, pauseSeconds: pauseSeconds ?? this.pauseSeconds);

  Map<String, Object?> toJson() => {
    'id': id, 'name': name,
    'steps': [for (final s in steps) s.toJson()],
    if (schedules.isNotEmpty) 'schedules': [for (final s in schedules) s.toJson()],
    if (repeat != 1) 'repeat': repeat,
    if (pauseSeconds != 0) 'pause': pauseSeconds,
  };

  static Routine? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'], name = json['name'], steps = json['steps'], schedules = json['schedules'];
    if (id is! String || id.isEmpty || name is! String || name.trim().isEmpty || steps is! List) return null;
    final repeat = json['repeat'], pause = json['pause'];
    return Routine(id: id, name: name.trim(), steps: [for (final s in steps) ?RoutineStep.fromJson(s)],
        schedules: [if (schedules is List) for (final s in schedules) ?RoutineSchedule.fromJson(s)],
        repeat: repeat is int ? repeat.clamp(0, maxRepeat) : 1,
        pauseSeconds: pause is int ? pause.clamp(0, 24 * 3600) : 0);
  }
}

/// "Once", "3 times", "Until stopped" (+ the wait between rounds).
String repeatText(Routine r, [AppLocalizations? strings]) {
  final s = strings ?? appStrings;
  final times = r.repeat == 0 ? s.untilStopped : r.repeat == 1 ? s.once : s.timesCount(r.repeat);
  if (r.repeat == 1 || r.pauseSeconds == 0) return times;
  return s.repeatApart(times, pauseText(r.pauseSeconds, s));
}

/// "30 s", "5 min".
String pauseText(int seconds, AppLocalizations s) =>
    seconds % 60 == 0 ? s.pauseMinutes(seconds ~/ 60) : s.pauseSeconds(seconds);

class RoutineError implements Exception {
  const RoutineError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The routines saved for one robot (per address, like places).
class RoutineBook extends ChangeNotifier {
  RoutineBook(this.robot);

  final String robot;
  /// Routines inside routines go at most this deep.
  static const maxDepth = 3;
  /// A routine expands to at most this many skill calls.
  static const maxCalls = 50;

  List<Routine> _routines = const [];
  bool _loaded = false;

  List<Routine> get routines => _routines;
  bool get loaded => _loaded;
  String get _key => 'routines:$robot';

  static String normalize(String name) => name.trim().toLowerCase();

  Routine? byId(String id) => _routines.where((r) => r.id == id).firstOrNull;
  Routine? find(String name) => _routines.where((r) => normalize(r.name) == normalize(name)).firstOrNull;

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final list = raw == null ? const [] : jsonDecode(raw);
      _routines = [if (list is List) for (final item in list) ?Routine.fromJson(item)];
    } catch (_) {
      _routines = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// Adds [routine], or replaces the one with its id. A different routine with the same name is replaced
  /// too (names are how people and the assistant refer to routines). Throws [RoutineError] if the steps
  /// would make a cycle or go too deep.
  Future<Routine> save(Routine routine) async {
    final r = routine.copyWith(name: routine.name.trim());
    if (r.name.isEmpty) throw const RoutineError('A routine needs a name.');
    final next = [
      for (final o in _routines)
        if (o.id != r.id && normalize(o.name) != normalize(r.name)) o,
      r,
    ];
    expand(r, lookup: (id) => id == r.id ? r : next.where((o) => o.id == id).firstOrNull); // validate
    _routines = next;
    notifyListeners();
    await _persist();
    return r;
  }

  Future<void> remove(String id) async {
    _routines = [for (final r in _routines) if (r.id != id) r];
    notifyListeners();
    await _persist();
  }

  /// Routines that use [id] as a step (so removing it would break them).
  List<Routine> usersOf(String id) =>
      [for (final r in _routines) if (r.steps.any((s) => s.routineId == id)) r];

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final r in _routines) r.toJson()]));
    } catch (_) {}
  }

  /// A fresh id for a new routine.
  static String newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The skill calls [routine] runs, with nested routines spliced in. Throws [RoutineError] for a missing
  /// routine, a cycle, nesting deeper than [maxDepth] or more than [maxCalls] calls.
  List<SkillCall> expand(Routine routine, {Routine? Function(String id)? lookup}) {
    final find = lookup ?? byId;
    final calls = <SkillCall>[];
    void walk(Routine r, List<String> path) {
      if (path.contains(r.id)) throw RoutineError('"${r.name}" includes itself.');
      if (path.length >= maxDepth) throw RoutineError('Routines are nested more than $maxDepth deep.');
      for (final step in r.steps) {
        if (step.call != null) {
          calls.add(step.call!);
          if (calls.length > maxCalls) throw const RoutineError('A routine can run at most $maxCalls steps.');
        } else {
          final inner = find(step.routineId!);
          if (inner == null) throw RoutineError('"${r.name}" uses a routine that was deleted.');
          walk(inner, [...path, r.id]);
        }
      }
    }
    walk(routine, const []);
    return calls;
  }
}

/// Whole seconds until [until], rounded up (a wait still running never reads "0 s").
int secondsLeft(DateTime until, {DateTime? now}) {
  final ms = until.difference(now ?? DateTime.now()).inMilliseconds;
  return ms <= 0 ? 0 : (ms + 999) ~/ 1000;
}
