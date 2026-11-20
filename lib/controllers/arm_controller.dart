import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../arm.dart';
import '../navigation_goal.dart' show RosVersion;
import '../ros_client.dart';

/// A named arm posture ("home", "carry", "look down"), joint name → position (rad or m).
class ArmPose {
  const ArmPose(this.name, this.joints);

  final String name;
  final Map<String, double> joints;

  Map<String, Object?> toJson() => {'name': name, 'joints': joints};

  static ArmPose? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], joints = json['joints'];
    if (name is! String || name.trim().isEmpty || joints is! Map || joints.isEmpty) return null;
    final values = <String, double>{};
    for (final e in joints.entries) {
      if (e.key is! String || e.value is! num || !(e.value as num).isFinite) return null;
      values[e.key as String] = (e.value as num).toDouble();
    }
    return ArmPose(name.trim(), values);
  }
}

/// The arm postures saved for one robot (per address and namespace, like places). The control screen
/// saves the arm's current posture under a name; the AI assistant can only move the arm to these, never
/// to joint values it makes up. "home" (every joint at 0) always exists.
class ArmPoseBook extends ChangeNotifier {
  ArmPoseBook(this.robot);

  final String robot;
  static const home = 'home';
  List<ArmPose> _poses = const [];
  bool _loaded = false;

  List<ArmPose> get poses => _poses;
  bool get loaded => _loaded;
  String get _key => 'arm_poses:$robot';

  static String normalize(String name) => name.trim().toLowerCase();

  /// The saved pose called [name], or "home" for [joints] (all zero) when not saved otherwise.
  ArmPose? find(String name, {List<String> joints = const []}) {
    final saved = _poses.where((p) => normalize(p.name) == normalize(name)).firstOrNull;
    if (saved != null || normalize(name) != home || joints.isEmpty) return saved;
    return ArmPose(home, {for (final j in joints) j: 0.0});
  }

  /// Names to offer: the saved ones, plus "home" if none is called that.
  List<String> names() => [
    for (final p in _poses) p.name,
    if (!_poses.any((p) => normalize(p.name) == home)) home,
  ];

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final list = raw == null ? const [] : jsonDecode(raw);
      _poses = [if (list is List) for (final item in list) ?ArmPose.fromJson(item)];
    } catch (_) {
      _poses = const [];
    }
    _loaded = true;
    notifyListeners();
  }

  /// Saves [pose], replacing one with the same name.
  Future<void> save(ArmPose pose) async {
    _poses = [for (final p in _poses) if (normalize(p.name) != normalize(pose.name)) p, pose];
    notifyListeners();
    await _persist();
  }

  Future<void> remove(String name) async {
    _poses = [for (final p in _poses) if (normalize(p.name) != normalize(name)) p];
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      await (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode([for (final p in _poses) p.toJson()]));
    } catch (_) {}
  }
}

/// How a commanded arm motion ended.
enum ArmEnd { reached, timeUp, interrupted, failed }

/// The robot's arm for the AI assistant: follows joint states, moves to a posture by a one-point
/// trajectory and waits until the joints get there, opens and closes the gripper. (The control screen
/// drives the arm on its own for jogging and dragging.)
class ArmController extends ChangeNotifier {
  ArmController(this.ros);

  final RosClient ros;
  ArmConfig? _config;
  RosVersion _version = RosVersion.ros2;
  RosPublisher? _trajectory;
  StreamSubscription<Map<String, dynamic>>? _states, _description;
  final Map<String, double> _positions = {};
  List<String> _names = const [];
  Map<String, JointLimit> _limits = const {};
  DateTime? _lastState;
  int _generation = 0;

  /// Joint speed for assistant moves (rad/s for the largest joint change): slow, the arm may be near people.
  static const speed = 0.5;
  /// How close every joint must get to count as arrived (rad).
  static const tolerance = 0.05;

  ArmConfig? get config => _config;
  bool get configured => _config != null;
  bool get hasGripper => (_config?.gripperAction ?? '').isNotEmpty;
  Map<String, double> get positions => Map.unmodifiable(_positions);
  /// The arm's joints (not wheels or gripper fingers), in URDF order when known.
  List<String> get joints => armJoints(_names, pinned: _config?.joints ?? const []);
  bool get isFresh => _lastState != null && DateTime.now().difference(_lastState!) < const Duration(seconds: 1);

  /// Follows the arm described by [config]; null forgets it.
  void configure(ArmConfig? config, RosVersion version, {String jointStatesTopic = '/joint_states',
      String robotDescriptionTopic = '/robot_description'}) {
    stop();
    _trajectory?.close();
    _trajectory = null;
    _states?.cancel();
    _description?.cancel();
    _config = config;
    _version = version;
    if (config != null) {
      try {
        _trajectory = ros.advertise(config.trajectoryTopic, 'trajectory_msgs/JointTrajectory');
        _states = ros.subscribe(jointStatesTopic, type: 'sensor_msgs/JointState', throttleRate: 50)
            .listen(_onStates, onError: (_) {});
        _description = ros.subscribe(robotDescriptionTopic, type: 'std_msgs/String')
            .listen(_onDescription, onError: (_) {});
      } catch (_) {}
    }
    notifyListeners();
  }

  void _onStates(Map<String, dynamic> msg) {
    final names = msg['name'], values = msg['position'];
    if (names is! List || values is! List) return;
    for (var i = 0; i < names.length && i < values.length; i++) {
      final v = values[i];
      if (v is num) _positions['${names[i]}'] = v.toDouble();
    }
    if (_names.length != _positions.length) _names = _positions.keys.toList();
    _lastState = DateTime.now();
  }

  void _onDescription(Map<String, dynamic> msg) {
    final urdf = msg['data'];
    if (urdf is String) _limits = parseJointLimits(urdf);
  }

  /// Waits up to [timeout] for the first joint states.
  Future<bool> waitFresh({Duration timeout = const Duration(seconds: 3)}) async {
    final end = DateTime.now().add(timeout);
    while (!isFresh) {
      if (DateTime.now().isAfter(end)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return true;
  }

  /// Moves the arm joints in [targets] (others stay) and waits until they are within [tolerance].
  /// Targets are clamped to the URDF limits. Interrupted by [stop].
  Future<ArmEnd> moveTo(Map<String, double> targets) async {
    final pub = _trajectory;
    if (pub == null || !await waitFresh()) return ArmEnd.failed;
    final names = joints;
    if (names.isEmpty) return ArmEnd.failed;
    final from = [for (final j in names) _positions[j] ?? 0.0];
    final to = [for (final j in names) (_limits[j] ?? fallbackLimit).clamp(targets[j] ?? _positions[j] ?? 0.0)];
    final seconds = moveDuration(from, to, speed);
    final generation = ++_generation;
    try {
      pub.publish(trajectoryMessage(names, to, seconds, _version));
    } catch (_) {
      return ArmEnd.failed;
    }
    final end = DateTime.now().add(Duration(milliseconds: (seconds * 1500 + 2000).round()));
    while (DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (generation != _generation) return ArmEnd.interrupted;
      var arrived = true;
      for (var i = 0; i < names.length; i++) {
        if (((_positions[names[i]] ?? from[i]) - to[i]).abs() > tolerance) arrived = false;
      }
      if (arrived) return ArmEnd.reached;
    }
    return ArmEnd.timeUp;
  }

  /// The largest joint difference from [targets], for reporting.
  double errorTo(Map<String, double> targets) {
    var worst = 0.0;
    for (final j in joints) {
      final t = targets[j];
      if (t == null) continue;
      final clamped = (_limits[j] ?? fallbackLimit).clamp(t);
      final d = ((_positions[j] ?? 0) - clamped).abs();
      if (d > worst) worst = d;
    }
    return worst;
  }

  /// Opens or closes the gripper and waits for the GripperCommand result.
  Future<ActionStatus> gripper(bool open) async {
    final action = _config?.gripperAction ?? '';
    if (action.isEmpty) return ActionStatus.failed;
    final joint = gripperJoint(_names);
    final limit = (joint == null ? null : _limits[joint]) ?? const JointLimit(-0.01, 0.019);
    final handle = ros.sendActionGoal(action, 'control_msgs/action/GripperCommand',
        {'command': {'position': open ? limit.upper : limit.lower, 'max_effort': 1.0}}, feedback: false);
    final r = await handle.result.timeout(const Duration(seconds: 10),
        onTimeout: () {
          handle.cancel();
          return const ActionResult(ActionStatus.failed, error: 'No answer from the gripper.');
        });
    // A gripper that closes on an object stops short of its target and may report aborted.
    return r.status == ActionStatus.aborted && !open ? ActionStatus.succeeded : r.status;
  }

  /// Holds the arm where it is (ends a running move).
  void stop() {
    _generation++;
    final pub = _trajectory;
    final names = joints;
    if (pub == null || names.isEmpty || !isFresh) return;
    try {
      pub.publish(holdMessage(names, [for (final j in names) _positions[j] ?? 0.0], _version));
    } catch (_) {}
  }

  @override
  void dispose() {
    _states?.cancel();
    _description?.cancel();
    _trajectory?.close();
    super.dispose();
  }
}
