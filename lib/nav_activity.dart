// What Nav2 is doing right now, read from its behavior tree log (`nav2_msgs/BehaviorTreeLog` on
// `<namespace>/behavior_tree_log`, published by bt_navigator on every node status change).
//
// The tree's nodes are named in the robot's BT XML; the defaults (and most custom trees) keep the action
// names: ComputePathToPose, FollowPath, Spin, BackUp, Wait, DriveOnHeading, ClearLocalCostmap-…, so the
// names are matched loosely. While the route is followed Nav2 re-plans every second; that is not news,
// so following wins over planning. A recovery (spin, back up, wait) wins over both.

enum NavActivity { planning, following, clearing, spinning, backingUp, waiting, drivingOnHeading, recovering }

/// The activity a behavior tree node stands for, or null for structural nodes (sequences, conditions).
NavActivity? activityOfNode(String name) {
  final n = name.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (n.contains('spin')) return NavActivity.spinning;
  if (n.contains('backup')) return NavActivity.backingUp;
  if (n.contains('driveonheading')) return NavActivity.drivingOnHeading;
  if (n.contains('assistedteleop')) return NavActivity.recovering;
  if (n == 'wait' || n.startsWith('wait') && !n.contains('waypoint')) return NavActivity.waiting;
  if (n.contains('clear') && n.contains('costmap')) return NavActivity.clearing;
  if (n.contains('followpath') || n.contains('followwaypoints') || n.contains('followroute')) return NavActivity.following;
  if (n.contains('computepath') || n.contains('computeroute') || n.contains('smoothpath')) return NavActivity.planning;
  return null;
}

bool isRecovery(NavActivity a) => a != NavActivity.planning && a != NavActivity.following;

/// The behavior tree log topic next to a NavigateToPose action (`/robot1/navigate_to_pose` →
/// `/robot1/behavior_tree_log`).
String behaviorTreeLogTopic(String navigateAction) {
  final i = navigateAction.lastIndexOf('/');
  return '${i <= 0 ? '' : navigateAction.substring(0, i)}/behavior_tree_log';
}

class NavActivityTracker {
  final _running = <String>{};
  /// Where the trip is, from the last meaningful change: bt_navigator logs a planner's RUNNING and the
  /// recoveries' RUNNING, but FollowPath often only as SUCCESS or FAILURE (Jazzy), so "a route was found"
  /// is what starts following.
  NavActivity? _phase;
  /// Recovery actions started since [reset] (Nav2's own count is of recovery rounds, not actions).
  int recoveryActions = 0;
  /// The last recovery action that ran, for "it may be stuck: it kept turning in place".
  NavActivity? lastRecovery;

  /// What it is doing: a running recovery first, else the trip's phase; null when unknown.
  NavActivity? get current {
    final recovery = [for (final n in _running) ?activityOfNode(n)].where(isRecovery).firstOrNull;
    return recovery ?? _phase;
  }

  /// Takes one BehaviorTreeLog; true when [current] changed.
  bool onLog(Object? msg) {
    if (msg is! Map) return false;
    final before = current;
    for (final e in (msg['event_log'] as List? ?? const [])) {
      if (e is! Map) continue;
      final name = '${e['node_name'] ?? ''}';
      final a = activityOfNode(name);
      if (a == null) continue;
      final status = '${e['current_status']}'.toUpperCase();
      if (status == 'RUNNING') {
        final started = _running.add(name);
        if (a == NavActivity.planning) {
          // Re-planning while following is routine (every second): not a change of what it does.
          if (_phase != NavActivity.following) _phase = NavActivity.planning;
        } else if (a == NavActivity.following) {
          _phase = NavActivity.following;
        } else if (started && a != NavActivity.clearing) {
          recoveryActions++;
          lastRecovery = a;
        }
        continue;
      }
      _running.remove(name);
      if (status == 'SUCCESS' && a == NavActivity.planning && _phase != NavActivity.following) {
        _phase = NavActivity.following; // a route: the controller takes it from here
      } else if (status == 'FAILURE' && a == NavActivity.following) {
        _phase = NavActivity.planning; // the controller gave up: recoveries and a new route come next
      } else if ((status == 'SUCCESS' || status == 'FAILURE') && isRecovery(a)) {
        _phase = NavActivity.planning; // after a recovery Nav2 plans again
      }
    }
    return current != before;
  }

  void reset() {
    _running.clear();
    _phase = null;
    recoveryActions = 0;
    lastRecovery = null;
  }
}
