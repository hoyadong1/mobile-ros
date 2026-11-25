import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'arm.dart';
import 'mjpeg.dart';

/// How the robot moves, which decides the controller layout and command message.
enum DriveType {
  /// Turns in place, no sideways motion (TurtleBot, most AMRs). Twist x + yaw.
  differential,
  /// Moves sideways too (mecanum, omni wheels). Twist x + y + yaw.
  holonomic,
  /// Steers like a car and cannot turn in place. AckermannDriveStamped speed + steering angle.
  ackermann,
  /// No mobile base (a fixed arm): only the arm panel is shown.
  none,
  /// Multirotor through MAVROS (PX4 / ArduPilot): velocity setpoints plus flight-mode services.
  aerial,
}

/// rosImage covers sensor_msgs/Image and CompressedImage topics over rosbridge; mjpeg is an HTTP
/// multipart JPEG stream such as ROS web_video_server.
enum CameraSource { rosImage, rtsp, mjpeg, none }

class RobotProfile {
  final DriveType drive;
  final String commandTopic;
  final CameraSource cameraSource;
  final String cameraTopic;
  final String rtspUrl;
  final String mjpegUrl;
  final double maxLinear; // m/s at full stick on the "Fast" preset
  final double maxAngular; // rad/s (differential / holonomic)
  final double maxSteering; // rad (ackermann)
  final ArmConfig? arm; // present for arms and mobile manipulators
  /// Manual topic choices; empty means "find automatically" (by message type).
  final String odomTopic;
  final String jointStatesTopic;

  const RobotProfile({
    required this.drive,
    required this.commandTopic,
    this.cameraSource = CameraSource.rosImage,
    this.cameraTopic = '/camera/image_raw',
    this.rtspUrl = '',
    this.mjpegUrl = '',
    this.maxLinear = 0.5,
    this.maxAngular = 1.0,
    this.maxSteering = 0.4,
    this.arm,
    this.odomTopic = '',
    this.jointStatesTopic = '',
  });

  /// Defaults per drive type; the command topic follows ROS conventions for each.
  factory RobotProfile.defaults(DriveType drive, {String? commandTopic, String? cameraTopic, String rtspUrl = '',
      ArmConfig? arm}) =>
      RobotProfile(
        drive: drive,
        commandTopic: commandTopic ?? defaultCommandTopic(drive),
        // No image topic means no camera until the user picks one; guessing an RTSP address would
        // keep a player retrying a stream that probably does not exist.
        cameraSource: cameraTopic == null ? CameraSource.none : CameraSource.rosImage,
        cameraTopic: cameraTopic ?? '/camera/image_raw',
        rtspUrl: rtspUrl,
        maxLinear: defaultMaxLinear(drive),
        arm: arm,
      );

  static String defaultCommandTopic(DriveType drive) => switch (drive) {
    DriveType.ackermann => '/ackermann_cmd',
    DriveType.aerial => '/mavros/setpoint_velocity/cmd_vel_unstamped',
    _ => '/cmd_vel',
  };

  static double defaultMaxLinear(DriveType drive) => switch (drive) {
    DriveType.ackermann => 1.0,
    DriveType.aerial => 2.0, // horizontal m/s on Fast; vertical is half of it
    _ => 0.5,
  };

  bool get hasBase => drive != DriveType.none;

  String get commandType => drive == DriveType.ackermann
      ? 'ackermann_msgs/AckermannDriveStamped' : 'geometry_msgs/Twist';

  /// [commandType] for a robot whose command topic is of [topicType] (as the robot lists it): a velocity
  /// topic typed `TwistStamped` gets stamped messages, everything else stays as configured.
  String commandTypeOn(String? topicType) =>
      drive != DriveType.ackermann && isTwistStamped(topicType) ? 'geometry_msgs/TwistStamped' : commandType;

  RobotProfile copyWith({DriveType? drive, String? commandTopic, CameraSource? cameraSource, String? cameraTopic,
      String? rtspUrl, String? mjpegUrl, double? maxLinear, double? maxAngular, double? maxSteering, ArmConfig? arm,
      bool clearArm = false, String? odomTopic, String? jointStatesTopic}) => RobotProfile(
    drive: drive ?? this.drive,
    commandTopic: commandTopic ?? this.commandTopic,
    cameraSource: cameraSource ?? this.cameraSource,
    cameraTopic: cameraTopic ?? this.cameraTopic,
    rtspUrl: rtspUrl ?? this.rtspUrl,
    mjpegUrl: mjpegUrl ?? this.mjpegUrl,
    maxLinear: maxLinear ?? this.maxLinear,
    maxAngular: maxAngular ?? this.maxAngular,
    maxSteering: maxSteering ?? this.maxSteering,
    arm: clearArm ? null : arm ?? this.arm,
    odomTopic: odomTopic ?? this.odomTopic,
    jointStatesTopic: jointStatesTopic ?? this.jointStatesTopic,
  );

  Map<String, dynamic> toJson() => {
    'drive': drive.name, 'commandTopic': commandTopic, 'cameraSource': cameraSource.name,
    'cameraTopic': cameraTopic, 'rtspUrl': rtspUrl, 'mjpegUrl': mjpegUrl,
    'maxLinear': maxLinear, 'maxAngular': maxAngular, 'maxSteering': maxSteering,
    if (arm != null) 'arm': arm!.toJson(),
    if (odomTopic.isNotEmpty) 'odomTopic': odomTopic,
    if (jointStatesTopic.isNotEmpty) 'jointStatesTopic': jointStatesTopic,
  };

  static RobotProfile? fromJson(Map<String, dynamic> json) {
    try {
      return RobotProfile(
        drive: DriveType.values.byName(json['drive'] as String),
        commandTopic: json['commandTopic'] as String,
        cameraSource: CameraSource.values.byName(json['cameraSource'] as String),
        cameraTopic: json['cameraTopic'] as String,
        rtspUrl: json['rtspUrl'] as String,
        mjpegUrl: json['mjpegUrl'] as String? ?? '', // absent in profiles saved before MJPEG support
        maxLinear: (json['maxLinear'] as num).toDouble(),
        maxAngular: (json['maxAngular'] as num).toDouble(),
        maxSteering: (json['maxSteering'] as num).toDouble(),
        arm: ArmConfig.fromJson(json['arm']),
        odomTopic: json['odomTopic'] as String? ?? '', // absent before manual topic settings
        jointStatesTopic: json['jointStatesTopic'] as String? ?? '',
      );
    } catch (_) {
      return null; // stored by an older/newer version: ask again instead of crashing
    }
  }
}

/// Remembers one profile per robot address.
class ProfileStore {
  static String _key(String host, String port) => 'robot_profile:$host:$port';
  /// The same, by a saved robot's address key (`host:port` and namespace, see RobotSession.storeAddress).
  static Future<RobotProfile?> loadAt(String address) {
    final i = address.indexOf(':');
    return load(i < 0 ? address : address.substring(0, i), i < 0 ? '' : address.substring(i + 1));
  }

  static Future<void> saveAt(String address, RobotProfile profile) {
    final i = address.indexOf(':');
    return save(i < 0 ? address : address.substring(0, i), i < 0 ? '' : address.substring(i + 1), profile);
  }

  static Future<RobotProfile?> load(String host, String port) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(host, port));
      return raw == null ? null : RobotProfile.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(String host, String port, RobotProfile profile) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(host, port), jsonEncode(profile.toJson()));
    } catch (_) { /* the profile still applies for this session */ }
  }
}

/// A best guess from rosapi `/rosapi/topics` (and action servers, for a gripper); the user confirms
/// it. A Twist topic alone cannot tell differential from holonomic, so that defaults to differential.
RobotProfile suggestProfile(Map<String, dynamic>? topicsResponse, {String rtspUrl = '',
    List<String> actionServers = const [], List<String> nodes = const [], String host = ''}) {
  final base = _suggestBase(topicsResponse, rtspUrl: rtspUrl, actionServers: actionServers);
  // Only raw images and a web_video_server on the robot: its MJPEG stream (JPEG over HTTP) is far
  // lighter than raw images through rosbridge.
  if (base.cameraSource == CameraSource.rosImage && host.isNotEmpty && nodes.any((n) => n.endsWith('web_video_server'))) {
    final topics = (topicsResponse?['topics'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
    final types = (topicsResponse?['types'] as List?)?.map((t) => '$t'.replaceFirst('/msg/', '/')).toList()
        ?? const <String>[];
    final i = topics.indexOf(base.cameraTopic);
    if (i >= 0 && i < types.length && types[i] == 'sensor_msgs/Image') {
      return base.copyWith(cameraSource: CameraSource.mjpeg, mjpegUrl: webVideoServerUrl(host, base.cameraTopic));
    }
  }
  return base;
}

RobotProfile _suggestBase(Map<String, dynamic>? topicsResponse, {String rtspUrl = '',
    List<String> actionServers = const []}) {
  final topics = (topicsResponse?['topics'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
  final types = (topicsResponse?['types'] as List?)?.map((t) => '$t'.replaceFirst('/msg/', '/')).toList()
      ?? const <String>[];
  String? firstOfType(String type, {bool Function(String topic)? prefer}) {
    final matches = [for (var i = 0; i < topics.length && i < types.length; i++) if (types[i] == type) topics[i]];
    if (matches.isEmpty) return null;
    return prefer == null ? matches.first : matches.firstWhere(prefer, orElse: () => matches.first);
  }

  bool colour(String t) {
    final name = t.toLowerCase();
    return !name.contains('depth') && (name.contains('color') || name.contains('rgb') || name.contains('image_raw'));
  }
  // Prefer a JPEG CompressedImage stream (~30x less bandwidth through rosbridge) over raw images.
  final compressed = firstOfType('sensor_msgs/CompressedImage', prefer: colour);
  final camera = compressed != null && !compressed.toLowerCase().contains('depth')
      ? compressed : firstOfType('sensor_msgs/Image', prefer: colour);
  final arm = suggestArm(topicsResponse, actionServers);
  // MAVROS: anchor on the velocity setpoint topic and require its sibling <ns>/state. (Matching any
  // ".../state" would pick e.g. /mavros/hil/state and fly on a topic that does not exist.)
  const setpoint = '/setpoint_velocity/cmd_vel_unstamped';
  for (final t in topics.where((t) => t.endsWith(setpoint))) {
    final ns = t.substring(0, t.length - setpoint.length);
    if (topics.contains('$ns/state')) {
      return RobotProfile.defaults(DriveType.aerial, commandTopic: t, cameraTopic: camera, rtspUrl: rtspUrl);
    }
  }
  final ackermann = firstOfType('ackermann_msgs/AckermannDriveStamped');
  if (ackermann != null) {
    return RobotProfile.defaults(DriveType.ackermann, commandTopic: ackermann, cameraTopic: camera,
        rtspUrl: rtspUrl, arm: arm);
  }
  final twist = topics.contains('/cmd_vel') ? '/cmd_vel' : firstOfType('geometry_msgs/Twist',
      prefer: (t) => t.endsWith('cmd_vel')) ?? firstOfType('geometry_msgs/TwistStamped', prefer: (t) => t.endsWith('cmd_vel'));
  if (twist == null && arm != null) {
    return RobotProfile.defaults(DriveType.none, cameraTopic: camera, rtspUrl: rtspUrl, arm: arm);
  }
  return RobotProfile.defaults(DriveType.differential, commandTopic: twist, cameraTopic: camera,
      rtspUrl: rtspUrl, arm: arm);
}

/// Whether a topic type (either spelling) is `geometry_msgs/TwistStamped`.
bool isTwistStamped(String? type) => type?.replaceFirst('/msg/', '/') == 'geometry_msgs/TwistStamped';
