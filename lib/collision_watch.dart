/// Nav2's collision monitor sits between the planner's velocity and the robot's wheels and slows or stops
/// it when something is inside a safety zone (`nav2_msgs/CollisionMonitorState`, usually on
/// `/collision_monitor_state`). While a person drives, "why does it not go?" is often this: the monitor is
/// holding the robot back, and only the robot knows.
enum CollisionAction { none, stop, slowdown, approach, limit }

CollisionAction collisionActionOf(Object? code) => switch (code) {
  1 => CollisionAction.stop,
  2 => CollisionAction.slowdown,
  3 => CollisionAction.approach,
  4 => CollisionAction.limit,
  _ => CollisionAction.none,
};

/// The topic of `nav2_msgs/CollisionMonitorState` among [topics] (name → type), the robot's own namespace
/// first, or null.
String? collisionTopicIn(Map<String, String> topics, {String namespace = ''}) {
  final found = [
    for (final e in topics.entries)
      if (e.value.replaceFirst('/msg/', '/') == 'nav2_msgs/CollisionMonitorState') e.key,
  ]..sort();
  if (found.isEmpty) return null;
  final ns = namespace == '/' ? '' : namespace;
  if (ns.isNotEmpty) return found.where((t) => t.startsWith('$ns/')).firstOrNull;
  return found.where((t) => t.split('/').length == 2).firstOrNull ?? (found.length == 1 ? found.first : null);
}

/// What the monitor is doing now: its last report. The monitor publishes when its state changes, not every
/// cycle (the TurtleBot3 simulation sent one message when it began to limit the speed and then stayed quiet
/// while it kept limiting), so a report holds until the next one. A robot standing in front of an obstacle
/// for minutes is still blocked.
class CollisionWatch {
  CollisionAction _action = CollisionAction.none;
  String _polygon = '';

  /// Takes one message; true when what [current] says changed.
  bool onMessage(Object? msg, [DateTime? now]) {
    if (msg is! Map) return false;
    final before = current();
    _action = collisionActionOf(msg['action_type']);
    _polygon = '${msg['polygon_name'] ?? ''}';
    return before != current();
  }

  /// The action and the zone that caused it, or null when the monitor is not holding the robot back.
  (CollisionAction, String)? current([DateTime? now]) =>
      _action == CollisionAction.none ? null : (_action, _polygon);

  /// Forgets the last report (the link to the robot was lost: it can no longer be known).
  void clear() {
    _action = CollisionAction.none;
    _polygon = '';
  }
}
