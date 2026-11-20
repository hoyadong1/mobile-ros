/// Whether a robot driving to a goal has stopped getting closer: "stuck" for a fleet operator (Brain Corp,
/// Drobot and Seegrid alert on it). Nav2 may spin, back up and retry for a long time without failing the
/// goal, so a person away from the screen would never know.
///
/// Fed the distance left at any rate; reports stuck once per goal, when the distance has not dropped by
/// [minProgress] for [window].
class NavProgressWatch {
  NavProgressWatch({this.window = const Duration(seconds: 45), this.minProgress = 0.15});

  final Duration window;
  final double minProgress;

  double? _best;
  DateTime? _bestAt;
  bool _reported = false;
  int? _goal;

  /// [remaining] metres left on an active goal (null when no goal is active). True exactly once per goal,
  /// at the moment it counts as stuck.
  bool update(double? remaining, DateTime now, {int? goal}) {
    if (goal != _goal) {
      _goal = goal;
      _best = null;
      _bestAt = null;
      _reported = false;
    }
    if (remaining == null) {
      _best = null;
      _bestAt = null;
      _reported = false;
      return false;
    }
    if (_best == null || remaining < _best! - minProgress) {
      _best = remaining;
      _bestAt = now;
      return false;
    }
    if (_reported || now.difference(_bestAt!) < window) return false;
    _reported = true;
    return true;
  }
}
