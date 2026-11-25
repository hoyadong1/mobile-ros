import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'map_geometry.dart' show Pose2D;
import 'ros_client.dart';

/// A round through several places with Nav2's FollowWaypoints: the robot drives to each in turn, stopping
/// at every one, and (when asked) starts again from the first. Unlike a routine of single trips it is one
/// goal for Nav2: one cancel, one progress, and no gap between two places where the robot waits for the phone.
const followWaypointsAction = '/follow_waypoints';
const followWaypointsType = 'nav2_msgs/action/FollowWaypoints';

enum PatrolStatus { idle, running, finished, canceled, failed }

class PatrolStop {
  const PatrolStop(this.name, this.pose);

  final String name;
  final Pose2D pose;
}

/// The goal for [stops] in [frame] (stamps zero: "now" for Nav2).
Map<String, dynamic> followWaypointsArgs(List<PatrolStop> stops, {String frame = 'map'}) => {
  'poses': [
    for (final s in stops) {
      'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': frame},
      'pose': {
        'position': {'x': s.pose.x, 'y': s.pose.y, 'z': 0.0},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': math.sin(s.pose.yaw / 2), 'w': math.cos(s.pose.yaw / 2)},
      },
    },
  ],
};

class PatrolController extends ChangeNotifier {
  PatrolController(this.ros);

  final RosClient ros;

  String? _action;
  PatrolStatus _status = PatrolStatus.idle;
  List<PatrolStop> _stops = const [];
  String _frame = 'map';
  bool _loop = false;
  int _current = 0, _laps = 0;
  final _missed = <int>{};
  String? _detail;
  ActionHandle? _handle;
  StreamSubscription<Map<String, dynamic>>? _feedback;
  Completer<PatrolStatus>? _finished;
  bool _disposed = false;

  /// The robot's FollowWaypoints action server, or null when it has none.
  String? get action => _action;
  bool get available => _action != null;
  PatrolStatus get status => _status;
  bool get isRunning => _status == PatrolStatus.running;
  List<PatrolStop> get stops => _stops;
  bool get loop => _loop;
  /// The stop it is driving to (0-based).
  int get current => _current;
  /// Rounds completed so far.
  int get laps => _laps;
  /// Stops Nav2 gave up on in the last round (it carries on with the next).
  Set<int> get missed => Set.unmodifiable(_missed);
  String? get detail => _detail;
  String? get currentName => _stops.isEmpty ? null : _stops[_current.clamp(0, _stops.length - 1)].name;

  /// Points the controller at the robot's FollowWaypoints action server: the one in [actionNames] (the
  /// robot's own namespace first), or none.
  void configure(List<String> actionNames, {String namespace = ''}) {
    final mine = actionNames.where((a) => a == followWaypointsAction || a.endsWith('/follow_waypoints')).toList();
    final ns = namespace == '/' ? '' : namespace;
    String? found;
    if (mine.isNotEmpty) {
      found = ns.isNotEmpty
          ? mine.where((a) => a == '$ns/follow_waypoints').firstOrNull
          : mine.where((a) => a == followWaypointsAction).firstOrNull ?? (mine.length == 1 ? mine.first : null);
    }
    if (found == _action) return;
    _action = found;
    notifyListeners();
  }

  /// Starts a round through [stops] (at least two). Completes with how it ended. A round that is running is
  /// replaced.
  Future<PatrolStatus> start(List<PatrolStop> stops, {String frame = 'map', bool loop = false}) {
    final action = _action;
    if (_disposed) throw StateError('PatrolController was disposed');
    if (action == null) throw StateError('This robot has no FollowWaypoints action.');
    if (stops.length < 2) throw ArgumentError('A patrol needs at least two places.');
    _detach(PatrolStatus.canceled);
    final finished = _finished = Completer<PatrolStatus>();
    _stops = List.unmodifiable(stops);
    _frame = frame;
    _loop = loop;
    _status = PatrolStatus.running;
    _current = 0;
    _laps = 0;
    _detail = null;
    _missed.clear();
    _send();
    notifyListeners();
    return finished.future;
  }

  void _send() {
    final handle = ros.sendActionGoal(_action!, followWaypointsType, followWaypointsArgs(_stops, frame: _frame));
    _handle = handle;
    _feedback?.cancel();
    _feedback = handle.feedback.listen((values) {
      final i = values['current_waypoint'];
      if (_handle != handle || i is! num) return;
      _current = i.toInt().clamp(0, _stops.length - 1);
      notifyListeners();
    });
    handle.result.then((result) {
      if (_handle != handle) return; // replaced, cancelled or disposed
      switch (result.status) {
        case ActionStatus.succeeded:
          _missed
            ..clear()
            ..addAll(_missedIn(result.values));
          if (_missed.length >= _stops.length) {
            _complete(PatrolStatus.failed, detail: 'Nav2 could not reach any of the places.');
          } else if (_loop) {
            _laps++;
            _current = 0;
            notifyListeners();
            _send();
          } else {
            _laps++;
            _complete(PatrolStatus.finished);
          }
        case ActionStatus.canceled:
          _complete(PatrolStatus.canceled);
        default:
          _complete(PatrolStatus.failed, detail: result.error ?? 'Nav2 stopped the patrol.');
      }
    });
  }

  static Set<int> _missedIn(Object? values) {
    final m = values is Map ? values['missed_waypoints'] : null;
    return m is List ? {for (final i in m) if (i is num) i.toInt()} : <int>{};
  }

  /// Stops the patrol (and the trip it is on). The status becomes canceled right away.
  void cancel() {
    if (!isRunning) return;
    final handle = _handle;
    try { handle?.cancel(); } catch (_) {}
    _complete(PatrolStatus.canceled);
  }

  void _complete(PatrolStatus status, {String? detail}) {
    if (!isRunning) return;
    _detach(status);
    _status = status;
    _detail = detail;
    notifyListeners();
  }

  void _detach(PatrolStatus status) {
    _feedback?.cancel();
    _feedback = null;
    _handle = null;
    final finished = _finished;
    _finished = null;
    if (finished != null && !finished.isCompleted) finished.complete(status);
  }

  /// Back to idle once the person has seen how it ended.
  void reset() {
    if (isRunning || _status == PatrolStatus.idle) return;
    _status = PatrolStatus.idle;
    _detail = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detach(PatrolStatus.failed);
    super.dispose();
  }
}
