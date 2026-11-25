import 'ros_client.dart';

/// What Nav2 offers to get a stuck robot going again, found among the robot's services. A person (or the
/// assistant) can clear what the costmaps remember: a person who walked past, a box that was moved, a
/// reflection the lidar took for a wall. The robot then plans again on what it sees now.
class NavTools {
  const NavTools({this.clearLocal, this.clearGlobal});

  /// `nav2_msgs/srv/ClearEntireCostmap` of the local and the global costmap.
  final String? clearLocal, clearGlobal;

  bool get canClearCostmaps => clearLocal != null || clearGlobal != null;

  static const none = NavTools();
}

/// The costmap services in [services], the robot's own namespace first (one connection can carry several
/// robots, each with its own `<ns>/local_costmap/…`).
NavTools navToolsIn(List<String> services, {String namespace = ''}) {
  String? find(String suffix) {
    final mine = services.where((s) => s.endsWith(suffix)).toList();
    if (mine.isEmpty) return null;
    final own = namespace.isEmpty || namespace == '/' ? null : mine.where((s) => s.startsWith('$namespace/')).firstOrNull;
    if (own != null) return own;
    // Another robot's costmap is not this robot's: with a namespace, only a service outside every namespace counts.
    if (namespace.isNotEmpty && namespace != '/') return mine.where((s) => s.split('/').length == suffix.split('/').length).firstOrNull;
    return mine.first;
  }

  return NavTools(
    clearLocal: find('/local_costmap/clear_entirely_local_costmap'),
    clearGlobal: find('/global_costmap/clear_entirely_global_costmap'),
  );
}

/// Clears both costmaps (the ones that exist). Returns how many answered; throws when none did.
Future<int> clearCostmaps(RosClient ros, NavTools tools) async {
  var cleared = 0;
  Object? failure;
  for (final service in [?tools.clearLocal, ?tools.clearGlobal]) {
    try {
      await ros.callService(service).timeout(const Duration(seconds: 10));
      cleared++;
    } catch (e) {
      failure = e;
    }
  }
  if (cleared == 0) throw failure ?? StateError('This robot has no costmap to clear.');
  return cleared;
}
