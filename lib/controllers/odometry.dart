import 'dart:async';
import 'dart:math' as math;
import '../drone.dart' show yawOf;
import '../map_geometry.dart' show Pose2D;
import '../ros_client.dart';

/// The robot's latest odometry pose (nav_msgs/Odometry), kept for code that needs to know how far the
/// robot actually moved, such as closed-loop agent moves. It does not notify listeners: odometry comes
/// at 10–50 Hz and readers poll [pose] when they need it.
class Odometry {
  Odometry(this.ros, {this.clock});

  final RosClient ros;
  /// Time source for freshness checks (tests); a monotonic stopwatch by default.
  final Duration Function()? clock;
  final _watch = Stopwatch()..start();

  String? _topic;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Pose2D? _pose;
  Duration? _at;

  /// The odometry topic in use, or null before [listen].
  String? get topic => _topic;

  /// Latest pose in the odometry frame (x, y in metres, yaw in radians), or null before the first message.
  Pose2D? get pose => _pose;

  /// Whether a message arrived within [maxAge]. A stale pose must not steer the robot.
  bool isFresh({Duration maxAge = const Duration(milliseconds: 500)}) {
    final at = _at;
    return at != null && _now() - at <= maxAge;
  }

  Duration _now() => clock?.call() ?? _watch.elapsed;

  /// Waits up to [timeout] for a fresh pose (right after [listen], the first message is still on its
  /// way). Returns whether one arrived.
  Future<bool> waitFresh({Duration timeout = const Duration(seconds: 1)}) async {
    final until = _now() + timeout;
    while (!isFresh()) {
      if (_topic == null || _now() >= until) return false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return true;
  }

  /// Follows [topic] (replacing a previous one). About 20 Hz is plenty for stopping within a centimetre
  /// or two at the agent's speeds.
  void listen(String topic, {int throttleRate = 50}) {
    if (_topic == topic && _sub != null) return;
    _sub?.cancel();
    _topic = topic;
    _pose = null;
    _at = null;
    _sub = ros.subscribe(topic, throttleRate: throttleRate).listen(_onMessage, onError: (_) {});
  }

  void _onMessage(Map<String, dynamic> msg) {
    final p = msg['pose'];
    final pose = p is Map ? p['pose'] : null;
    if (pose is! Map || pose['position'] is! Map) return;
    final position = pose['position'] as Map;
    final x = position['x'], y = position['y'];
    if (x is! num || y is! num) return;
    final q = pose['orientation'];
    final yaw = q is Map && q['w'] is num ? yawOf(q) : 0.0;
    if (!x.isFinite || !y.isFinite || !yaw.isFinite) return;
    _pose = Pose2D(x.toDouble(), y.toDouble(), yaw);
    _at = _now();
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}

/// Tracks progress of a straight move or a turn from odometry samples.
class MotionProgress {
  MotionProgress(Pose2D start) : _start = start, _lastYaw = start.yaw;

  final Pose2D _start;
  double _lastYaw;
  double _turned = 0;
  Pose2D? _latest;

  /// Straight-line distance from the start, metres.
  double get distance {
    final p = _latest;
    return p == null ? 0 : math.sqrt(math.pow(p.x - _start.x, 2) + math.pow(p.y - _start.y, 2));
  }

  /// Signed angle turned since the start, radians, counting full turns (not wrapped to ±π).
  double get turned => _turned;

  void update(Pose2D pose) {
    var d = pose.yaw - _lastYaw;
    while (d > math.pi) {
      d -= 2 * math.pi;
    }
    while (d < -math.pi) {
      d += 2 * math.pi;
    }
    _turned += d;
    _lastYaw = pose.yaw;
    _latest = pose;
  }
}
