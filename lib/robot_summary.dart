import 'navigation_goal.dart' show RosVersion;
import 'robot_capabilities.dart';
import 'robot_profile.dart';

/// One thing the robot can do or sense, as found on the network.
class RobotFeature {
  const RobotFeature(this.id, this.label, this.topics);

  final String id;
  final String label;
  /// Where it was found (topics or action servers). Empty means not detected.
  final List<String> topics;

  bool get detected => topics.isNotEmpty;
}

/// What the connected robot is and what it can do, from what it advertises (rosapi topics, action
/// servers, nodes). Only what was found is claimed: anything not seen is "not detected", never guessed.
class RobotSummary {
  const RobotSummary({required this.kind, required this.rosVersion, required this.features, this.model,
      this.topicCount = 0, this.nodeCount = 0, this.actionCount = 0, this.discovered = true});

  /// Plain description of the body, e.g. "Mobile robot (turns in place)".
  final String kind;
  /// A known robot model recognised from node or topic names (e.g. "TurtleBot3"), if any.
  final String? model;
  final RosVersion rosVersion;
  final List<RobotFeature> features;
  final int topicCount, nodeCount, actionCount;
  /// False when the robot did not answer discovery (no rosapi): then little is known.
  final bool discovered;

  RobotFeature? feature(String id) => features.where((f) => f.id == id).firstOrNull;
  bool has(String id) => feature(id)?.detected ?? false;

  /// What the AI assistant will be able to do with this robot, in plain words.
  List<String> get assistantCan => [
    if (has('drive')) kind.contains('car') ? 'drive and steer' : 'drive and turn',
    if (has('navigation')) 'go to points and saved places on the map',
    if (has('camera')) 'look through the camera',
    'report status',
    'run saved routines',
  ];

  static const _models = <(String, String)>[
    ('turtlebot4', 'TurtleBot4'), ('turtlebot3', 'TurtleBot3'), ('turtlebot', 'TurtleBot'),
    ('husky', 'Clearpath Husky'), ('jackal', 'Clearpath Jackal'), ('husarion', 'Husarion'), ('rosbot', 'Husarion ROSbot'),
    ('go2', 'Unitree Go2'), ('spot', 'Boston Dynamics Spot'), ('ur_', 'Universal Robots arm'),
    ('panda', 'Franka Panda'), ('fr3', 'Franka FR3'), ('xarm', 'UFACTORY xArm'), ('doosan', 'Doosan arm'),
    ('kinova', 'Kinova arm'), ('px4', 'PX4 drone'), ('mavros', 'MAVROS drone'),
  ];

  static String? _recognise(Iterable<String> names) {
    final all = names.map((n) => n.toLowerCase()).toList();
    for (final (key, name) in _models) {
      if (all.any((n) => n.contains(key))) return name;
    }
    return null;
  }

  /// Builds the summary from discovery and the robot profile in use (stored, or suggested from topics).
  factory RobotSummary.from(RobotCapabilities caps, {RobotProfile? profile}) {
    final p = profile ?? suggestProfile(caps.topics, actionServers: caps.actionServers, nodes: caps.nodes);
    // With several robots on the connection, a sensor topic outside this robot's namespace may be another
    // robot's (found with a base and a fixed arm side by side: the arm was shown with the base's lidar).
    // Only what is under its own namespace is claimed; the map is the exception, since robots share one.
    final ns = caps.namespace;
    final ownOnly = caps.sharesNetwork && ns.isNotEmpty;
    List<String> every(String type) => caps.topicsOfType(type);
    List<String> ofType(String type) =>
        ownOnly ? [for (final t in every(type)) if (t.startsWith('$ns/')) t] : every(type);
    // image_transport offers every camera as <topic>/compressedDepth too; that says nothing about the
    // camera being a depth camera, so such a topic counts only when its camera is one.
    const transport = '/compressedDepth';
    String camera(String t) => t.endsWith(transport) ? t.substring(0, t.length - transport.length) : t;
    bool depth(String t) => camera(t).toLowerCase().contains('depth');
    final images = [
      for (final t in [...ofType('sensor_msgs/CompressedImage'), ...ofType('sensor_msgs/Image')])
        if (!t.endsWith(transport) || depth(t)) t,
    ];
    // Navigation's own working data (costmaps, their point clouds) is not a sensor or the map.
    // Likewise MAVROS's obstacle input: a LaserScan it listens to, not a sensor it has.
    bool internal(String t) =>
        t.contains('costmap') || t.contains('clearing_endpoints') || t.contains('/mavros/obstacle/');
    List<String> real(List<String> ts) => [for (final t in ts) if (!internal(t)) t];
    final nav = [
      ?caps.actionNamed('navigate_to_pose'),
      ?caps.actionNamed('move_base'),
    ];
    final arm = p.arm == null ? const <String>[] : [p.arm!.trajectoryTopic, if (p.arm!.gripperAction.isNotEmpty) p.arm!.gripperAction];
    final maps = real(every('nav_msgs/OccupancyGrid'))..sort((a, b) => (b == '/map' ? 1 : 0) - (a == '/map' ? 1 : 0));
    final features = <RobotFeature>[
      RobotFeature('drive', 'Driving', p.hasBase && p.commandTopic.isNotEmpty && p.drive != DriveType.aerial
          ? [p.commandTopic] : const []),
      RobotFeature('odometry', 'Odometry', ofType('nav_msgs/Odometry')),
      RobotFeature('map', 'Map', maps),
      RobotFeature('navigation', 'Navigation (Nav2)', nav),
      RobotFeature('lidar', 'LiDAR', real(ofType('sensor_msgs/LaserScan'))),
      RobotFeature('camera', 'Camera', [for (final t in images) if (!depth(t)) t]),
      RobotFeature('depth', 'Depth / 3D', real([...[for (final t in images) if (depth(t)) t], ...ofType('sensor_msgs/PointCloud2')])),
      RobotFeature('imu', 'IMU', ofType('sensor_msgs/Imu')),
      RobotFeature('battery', 'Battery', ofType('sensor_msgs/BatteryState')),
      RobotFeature('gps', 'GPS', ofType('sensor_msgs/NavSatFix')),
      RobotFeature('arm', 'Arm', arm),
      RobotFeature('flight', 'Flight (MAVROS)', p.drive == DriveType.aerial ? [p.commandTopic] : const []),
    ];
    final kind = switch (p.drive) {
      DriveType.differential when p.arm != null => 'Mobile manipulator (base + arm)',
      DriveType.holonomic when p.arm != null => 'Mobile manipulator (base + arm)',
      DriveType.differential => p.commandTopic.isEmpty ? 'Robot (no drive topic found)' : 'Mobile robot (turns in place)',
      DriveType.holonomic => 'Mobile robot (moves in any direction)',
      DriveType.ackermann => 'Mobile robot (car-like steering)',
      DriveType.aerial => 'Drone',
      DriveType.none => p.arm != null ? 'Robot arm' : 'Robot without a mobile base',
    };
    return RobotSummary(
      kind: kind,
      model: _recognise([...caps.nodes, ...caps.topicNames]),
      rosVersion: caps.rosVersion,
      features: features,
      topicCount: caps.topicNames.length,
      nodeCount: caps.nodes.length,
      actionCount: caps.actionServers.length,
      discovered: caps.topics != null,
    );
  }
}
