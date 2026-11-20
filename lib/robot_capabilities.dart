import 'navigation_goal.dart' show RosVersion, detectRosVersion;
import 'ros_connection.dart';
import 'topic_discovery.dart';

/// What the robot offers, read once from rosapi: its topics (with types), action servers and nodes,
/// plus topic choices made from them. Screens that used to run this discovery each on their own
/// (control, map) share one snapshot per session, and later the AI agent reads its skill list from it.
///
/// Every rosapi call is optional: a robot without rosapi (or an old one) gives empty lists, and the
/// screens fall back to conventional names as before.
class RobotCapabilities {
  RobotCapabilities({required this._connection, this.topics, this.actionServers = const [],
      this.nodes = const [], this.namespace = '', this.sharesNetwork = false, DateTime? discoveredAt})
      : rosVersion = detectRosVersion(topics),
        discoveredAt = discoveredAt ?? DateTime.now();

  /// Asks rosapi for topics, action servers and nodes.
  static Future<RobotCapabilities> discover(RosConnection connection) async {
    Map<String, dynamic>? topics;
    try {
      topics = await connection.call('/rosapi/topics');
    } catch (_) {}
    var actions = <String>[];
    try {
      actions = List<String>.from((await connection.call('/rosapi/action_servers'))['action_servers'] as List? ?? const []);
    } catch (_) {} // ROS 1 or an older rosapi
    var nodes = <String>[];
    try {
      nodes = List<String>.from((await connection.call('/rosapi/nodes'))['nodes'] as List? ?? const []);
    } catch (_) {}
    return RobotCapabilities(connection: connection, topics: topics, actionServers: actions, nodes: nodes);
  }

  final RosConnection _connection;

  /// The raw /rosapi/topics answer ({topics: [...], types: [...]}), or null if rosapi did not answer.
  final Map<String, dynamic>? topics;
  final List<String> actionServers;
  final List<String> nodes;
  /// The robot this snapshot is about, e.g. `/robot1`, or '' for a robot at the root (see [scoped]).
  final String namespace;
  /// Whether other robots were found on the same connection. Topics outside every robot's namespace
  /// (a stray `/scan`) then cannot be said to be this robot's.
  final bool sharesNetwork;
  final RosVersion rosVersion;
  final DateTime discoveredAt;

  final _picks = <String, Future<String?>>{};

  List<String> get topicNames => (topics?['topics'] as List?)?.map((t) => '$t').toList() ?? const [];

  /// Topics of [type], ROS 1 or ROS 2 spelling.
  List<String> topicsOfType(String type) => _topicsOfType(topics, type);

  /// The topic of [type] to use, preferring the [conventional] name and skipping topics nobody
  /// publishes (for [TopicRole.read]) or listens (for [TopicRole.write]) on. See [pickTopic].
  /// Answers are remembered, so screens asking the same question share one set of rosapi calls.
  Future<String?> pick(String type, String conventional, {TopicRole role = TopicRole.read}) =>
      _picks.putIfAbsent('$type|$conventional|${role.name}',
          // In a robot's namespace its own `<ns>/odom` ranks first, before a shared `/odom`.
          () => pickTopic(_connection, topics, type,
              namespace.isEmpty ? conventional : '${namespace.substring(1)}/$conventional', role: role));

  /// The first action server named [name] or ending in `/name` (e.g. `navigate_to_pose`).
  String? actionNamed(String name) =>
      actionServers.where((a) => a == '/$name' || a.endsWith('/$name')).firstOrNull;

  Duration get age => DateTime.now().difference(discoveredAt);

  /// The robots on this network, by namespace: a namespace with a velocity command topic
  /// (`<ns>/cmd_vel`, Twist) or an arm trajectory topic next to its odometry or joint states. '' is a
  /// robot at the root (plain `/cmd_vel`). Ordered by name; empty when nothing looks like a robot.
  List<String> robotNamespaces() {
    final names = topicNames.toSet();
    final found = <String>{};
    for (final t in [...topicsOfType('geometry_msgs/Twist'), ...topicsOfType('trajectory_msgs/JointTrajectory')]) {
      final slash = t.lastIndexOf('/');
      var ns = t.substring(0, slash);
      // e.g. /robot1/arm_controller/joint_trajectory: the robot is the first segment.
      if (!names.contains('$ns/odom') && !names.contains('$ns/joint_states')) {
        final first = t.indexOf('/', 1);
        ns = first > 0 ? t.substring(0, first) : '';
      }
      if (names.contains('$ns/odom') || names.contains('$ns/joint_states')) found.add(ns);
    }
    return found.toList()..sort();
  }

  /// This snapshot seen from one robot: its own topics, action servers and nodes (under [ns]) plus the
  /// shared ones that belong to no robot in [robots]. Everything that picks topics from the snapshot
  /// (driving, map, navigation, summary) then finds that robot's `/robot1/cmd_vel`, `/robot1/map`, …
  RobotCapabilities scoped(String ns, List<String> robots) {
    final others = [for (final r in robots) if (r != ns && r.isNotEmpty) '$r/'];
    bool mine(String name) => ns.isNotEmpty
        ? name.startsWith('$ns/') || !others.any(name.startsWith)
        : !others.any(name.startsWith);
    final list = (topics?['topics'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
    final types = (topics?['types'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
    final keep = [for (var i = 0; i < list.length && i < types.length; i++) if (mine(list[i])) i];
    return RobotCapabilities(
      connection: _connection,
      topics: topics == null ? null : {
        ...topics!,
        'topics': [for (final i in keep) list[i]],
        'types': [for (final i in keep) types[i]],
      },
      actionServers: [for (final a in actionServers) if (mine(a)) a],
      nodes: [for (final n in nodes) if (mine(n)) n],
      namespace: ns,
      sharesNetwork: robots.length > 1,
      discoveredAt: discoveredAt,
    );
  }
}

List<String> _topicsOfType(Map<String, dynamic>? topics, String type) => topicsOfType(topics, type);
