import 'dart:async';
import 'routines.dart';

/// Runs routines at their scheduled times while the app is connected to the robot. Checks a few times a
/// minute and starts each due schedule once in its minute. (Running while the app is closed would need
/// an Android foreground service, or a scheduler on the robot.)
class RoutineScheduler {
  RoutineScheduler(this.book, {required this.run, DateTime Function()? clock,
      this.interval = const Duration(seconds: 15)})
      : clock = clock ?? DateTime.now;

  final RoutineBook book;
  final Future<void> Function(Routine routine) run;
  final DateTime Function() clock;
  final Duration interval;
  final Set<String> _started = {};
  Timer? _timer;

  void start() {
    _timer ??= Timer.periodic(interval, (_) => check());
  }

  /// Starts every routine due now that has not started in this minute. Returns the ones started.
  List<Routine> check() {
    final now = clock();
    final minute = '${now.year}-${now.month}-${now.day} ${now.hour}:${now.minute}';
    final due = <Routine>[];
    for (final r in book.routines) {
      for (final (i, s) in r.schedules.indexed) {
        final key = '${r.id}/$i@$minute';
        if (s.dueAt(now) && _started.add(key)) {
          due.add(r);
          break;
        }
      }
    }
    if (_started.length > 500) _started.clear();
    for (final r in due) {
      unawaited(run(r));
    }
    return due;
  }

  /// The next scheduled run of any routine after now: (routine, time), or null.
  (Routine, DateTime)? next() {
    final now = clock();
    (Routine, DateTime)? best;
    for (final r in book.routines) {
      for (final s in r.schedules) {
        final t = s.nextAfter(now);
        if (t != null && (best == null || t.isBefore(best.$2))) best = (r, t);
      }
    }
    return best;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
