import 'navigation_goal.dart' show RosVersion;

/// How to command a ros2_control / ROS 1 arm: a JointTrajectoryController topic plus an optional
/// GripperCommand action. Joint names come from /joint_states at runtime unless pinned here.
class ArmConfig {
  final String trajectoryTopic; // e.g. /arm_controller/joint_trajectory
  final String gripperAction; // e.g. /gripper_controller/gripper_cmd ('' = no gripper)
  final List<String> joints; // empty = auto (joint_states minus wheels and gripper joints)

  const ArmConfig({required this.trajectoryTopic, this.gripperAction = '', this.joints = const []});

  Map<String, dynamic> toJson() => {'trajectoryTopic': trajectoryTopic, 'gripperAction': gripperAction, 'joints': joints};

  static ArmConfig? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return ArmConfig(trajectoryTopic: json['trajectoryTopic'] as String,
        gripperAction: json['gripperAction'] as String? ?? '',
        joints: List<String>.from(json['joints'] as List? ?? const []));
    } catch (_) {
      return null;
    }
  }

  ArmConfig copyWith({String? trajectoryTopic, String? gripperAction, List<String>? joints}) => ArmConfig(
    trajectoryTopic: trajectoryTopic ?? this.trajectoryTopic,
    gripperAction: gripperAction ?? this.gripperAction,
    joints: joints ?? this.joints,
  );
}

class JointLimit {
  final double lower, upper;
  const JointLimit(this.lower, this.upper);
  double clamp(double v) => v.clamp(lower, upper).toDouble();
}

const fallbackLimit = JointLimit(-3.14159, 3.14159);

/// Reads revolute/prismatic joint limits from a URDF string (no XML dependency needed).
Map<String, JointLimit> parseJointLimits(String urdf) {
  final limits = <String, JointLimit>{};
  final jointPattern = RegExp(r'<joint\b([^>]*)>(.*?)</joint>', dotAll: true);
  String? attr(String tag, String name) => RegExp('$name\\s*=\\s*"([^"]*)"').firstMatch(tag)?.group(1);
  for (final m in jointPattern.allMatches(urdf)) {
    final head = m.group(1)!;
    final type = attr(head, 'type');
    final name = attr(head, 'name');
    if (name == null || (type != 'revolute' && type != 'prismatic')) continue;
    final limitTag = RegExp(r'<limit\b([^>]*)/?>').firstMatch(m.group(2)!)?.group(1);
    final lower = double.tryParse(attr(limitTag ?? '', 'lower') ?? '');
    final upper = double.tryParse(attr(limitTag ?? '', 'upper') ?? '');
    if (lower != null && upper != null && upper > lower) limits[name] = JointLimit(lower, upper);
  }
  return limits;
}

/// Arm joints from a joint_states name list: everything except wheels and gripper fingers, ordered
/// like [urdfOrder] (the URDF lists joints base → tip; joint_states order is arbitrary, e.g.
/// joint2, joint1, joint4, joint3 from ros2_control). Joints missing from the URDF keep their order at the end.
List<String> armJoints(List<String> jointStateNames, {List<String> pinned = const [],
    List<String> urdfOrder = const []}) {
  if (pinned.isNotEmpty) return pinned;
  final joints = jointStateNames.where((n) {
    final l = n.toLowerCase();
    return !l.contains('wheel') && !l.contains('gripper') && !l.contains('finger') && !l.contains('caster');
  }).toList();
  if (urdfOrder.isEmpty) return joints;
  int rank(String j) {
    final i = urdfOrder.indexOf(j);
    return i < 0 ? urdfOrder.length + joints.indexOf(j) : i;
  }
  return joints..sort((a, b) => rank(a).compareTo(rank(b)));
}

/// The gripper joint (first one, mimic joints follow it) or null.
String? gripperJoint(List<String> jointStateNames) {
  for (final n in jointStateNames) {
    final l = n.toLowerCase();
    if (l.contains('gripper') || l.contains('finger')) return n;
  }
  return null;
}

/// Finds an arm from rosapi topics (JointTrajectory topic) and action servers (GripperCommand).
ArmConfig? suggestArm(Map<String, dynamic>? topicsResponse, List<String> actionServers) {
  final topics = (topicsResponse?['topics'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
  final types = (topicsResponse?['types'] as List?)?.map((t) => '$t'.replaceFirst('/msg/', '/')).toList()
      ?? const <String>[];
  final trajectory = [
    for (var i = 0; i < topics.length && i < types.length; i++)
      if (types[i] == 'trajectory_msgs/JointTrajectory') topics[i],
  ];
  if (trajectory.isEmpty) return null;
  trajectory.sort((a, b) => (b.contains('arm') ? 1 : 0) - (a.contains('arm') ? 1 : 0));
  final gripper = actionServers.firstWhere((a) => a.toLowerCase().contains('gripper'), orElse: () => '');
  return ArmConfig(trajectoryTopic: trajectory.first, gripperAction: gripper);
}

Map<String, dynamic> _duration(double seconds, RosVersion version) {
  final whole = seconds.floor();
  final nanos = ((seconds - whole) * 1e9).round();
  return version == RosVersion.ros2 ? {'sec': whole, 'nanosec': nanos} : {'secs': whole, 'nsecs': nanos};
}

Map<String, dynamic> _header(RosVersion version) => {
  'stamp': version == RosVersion.ros2 ? {'sec': 0, 'nanosec': 0} : {'secs': 0, 'nsecs': 0},
  'frame_id': '',
  if (version == RosVersion.ros1) 'seq': 0,
};

/// One-point trajectory to [positions] reached after [seconds] (stamp 0 = start now).
Map<String, dynamic> trajectoryMessage(List<String> joints, List<double> positions, double seconds, RosVersion version) => {
  'header': _header(version),
  'joint_names': joints,
  'points': [{
    'positions': positions,
    'velocities': <double>[],
    'accelerations': <double>[],
    'effort': <double>[],
    'time_from_start': _duration(seconds, version),
  }],
};

/// Stops the arm where it is: a short trajectory to the measured [positions] replaces whatever the
/// controller is executing. (An empty trajectory would be simpler, but the ROS 2 Humble
/// JointTrajectoryController rejects it as invalid and keeps moving: measured 0.63 rad of overrun.)
Map<String, dynamic> holdMessage(List<String> joints, List<double> positions, RosVersion version) =>
    trajectoryMessage(joints, positions, 0.2, version);

/// Time for the largest joint move at [speed] rad/s, never shorter than 0.25 s.
double moveDuration(List<double> from, List<double> to, double speed) {
  var largest = 0.0;
  for (var i = 0; i < from.length && i < to.length; i++) {
    final d = (to[i] - from[i]).abs();
    if (d > largest) largest = d;
  }
  final t = largest / (speed <= 0 ? 0.1 : speed);
  return t < 0.25 ? 0.25 : t;
}
