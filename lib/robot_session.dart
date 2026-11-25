import 'controllers/drive_controller.dart';
import 'controllers/navigation_controller.dart';
import 'controllers/odometry.dart';
import 'map_topics.dart';
import 'places.dart';
import 'robot_log.dart';
import 'robot_requests.dart';
import 'routines.dart';
import 'controllers/arm_controller.dart';
import 'navigation_goal.dart' show RosVersion;
import 'robot_capabilities.dart';
import 'memory.dart';
import 'robot_persona.dart';
import 'robot_profile.dart';
import 'ros_client.dart';
import 'ros_connection.dart';
import 'topic_discovery.dart' show TopicRole;

/// One robot connection as the workspace sees it: the main connection, how tools open their own
/// connections, a shared [RobotCapabilities] snapshot, and the controllers that move the robot.
///
/// The controllers live as long as the session, not a screen, so the AI agent can drive and navigate
/// whichever screen is open. Screens attach to them while open (the control screen feeds its sticks
/// into [drive], the map screen shows [nav]).
class RobotSession {
  RobotSession({required this.connection, required this.ip, required this.port, this.namespace = '',
      this.connectionFactory = RosConnection.new, this.maxAge = const Duration(seconds: 30), String? storeKey})
      : storeKey = storeKey ?? '$ip:$port';

  final RosConnection connection;
  final String ip;
  final String port;
  /// Which robot on the connection this session drives: `/robot1`, or '' for a robot at the root.
  /// Discovery is scoped to it (see [RobotCapabilities.scoped]), so every topic it picks is its own.
  final String namespace;

  /// The robot's name for people: the namespace without its slash, or the address for a root robot.
  String get name => namespace.isEmpty ? '$ip:$port' : namespace.substring(1);

  /// Which saved robot this is (see [RobotIdentity]): the address it was first seen at, so what is saved
  /// for it is found again when it is reached at another address.
  final String storeKey;

  /// Key for what is saved per robot (profile, topic choices, places, routines, memory).
  String get storeAddress => '$storeKey$namespace';

  /// How each tool opens its own connection: a new rosbridge socket, or a view on the direct session.
  final RosConnection Function(String, String) connectionFactory;

  /// A snapshot older than this is discovered again, so nodes started after connecting show up.
  final Duration maxAge;

  late final RosClient ros = RosClient(connection);
  late final DriveController drive = DriveController(ros);
  late final NavigationController nav = NavigationController(ros);
  /// The robot's odometry, followed once [prepare] has run (closed-loop agent moves read it).
  late final Odometry odometry = Odometry(ros);
  /// Named places on this robot's map (saved on the map page, used by the AI assistant).
  late final PlaceBook places = PlaceBook(storeAddress);
  /// Questions and notices from the robot to the person (started by the workspace).
  late final RobotRequests requests = RobotRequests(ros, namespace: namespace);
  /// Saved routines for this robot (the routines screen, schedules and the AI assistant share them).
  late final RoutineBook routines = RoutineBook(storeAddress);
  /// The arm, if the robot has one (configured by [prepare] from the profile), and its saved postures.
  late final ArmController arm = ArmController(ros);
  late final ArmPoseBook armPoses = ArmPoseBook(storeAddress);
  /// What the assistant knows about this robot (its name, role, manner, notes, later its history).
  /// The person's own memory is [Memory.user], shared by every robot.
  late final Memory memory = Memory(Memory.robotScope(storeAddress));

  /// The name the person gave the robot, else [name].
  String get label => memory.profile(RobotPersona.nameKey) ?? name;
  /// The robot's log (/rosout), collected from when the workspace starts it.
  late final RobotLog robotLog = RobotLog(ros);
  /// Common settings' values when they were first read in this connection (the tuning screen offers
  /// to go back to them).
  final Map<String, double> tuningStart = {};

  Future<RobotCapabilities>? _capabilities;
  DateTime? _startedAt;
  bool _disposed = false;

  /// The current snapshot; discovers on first use, after [maxAge], or after [invalidate].
  /// Callers opening at the same time share one discovery.
  Future<RobotCapabilities> capabilities() {
    final started = _startedAt;
    if (_capabilities == null || started == null || DateTime.now().difference(started) > maxAge) {
      _startedAt = DateTime.now();
      _capabilities = RobotCapabilities.discover(connection).then((all) {
        final robots = all.robotNamespaces();
        return robots.isEmpty && namespace.isEmpty ? all : all.scoped(namespace, robots);
      });
    }
    return _capabilities!;
  }

  /// Forgets the snapshot; the next [capabilities] call discovers again.
  void invalidate() {
    _capabilities = null;
    _startedAt = null;
  }

  /// Points [drive] and [nav] at the robot if no screen has yet: the saved robot profile (or the
  /// discovered suggestion) for driving, and the saved map topic choices (or discovery) for navigation.
  /// Advertises the command and goal topics, so it is called only when something is about to use
  /// them (the agent), not on connect.
  Future<void> prepare() async {
    if (_disposed) throw StateError('Robot session was closed');
    final caps = await capabilities();
    if (drive.profile == null) {
      final stored = await ProfileStore.loadAt(storeAddress);
      var profile = stored ?? suggestProfile(caps.topics, actionServers: caps.actionServers, nodes: caps.nodes);
      if (stored == null && (profile.drive == DriveType.differential || profile.drive == DriveType.holonomic)) {
        final command = await caps.pickVelocityCommand();
        if (command != null) profile = profile.copyWith(commandTopic: command);
      }
      if (drive.profile == null) { // a screen may have won the race
        drive.configure(profile, caps.rosVersion, commandTopicType: caps.typeOf(profile.commandTopic));
      }
    }
    if (!places.loaded) await places.load();
    await memory.load();
    await Memory.user.load();
    if (!routines.loaded) await routines.load();
    if (!armPoses.loaded) await armPoses.load();
    final armConfig = drive.profile?.arm;
    if (armConfig != null && !arm.configured) {
      arm.configure(armConfig, caps.rosVersion,
          jointStatesTopic: await caps.pick('sensor_msgs/JointState', 'joint_states') ?? '$namespace/joint_states',
          robotDescriptionTopic: await caps.pick('std_msgs/String', 'robot_description') ?? '$namespace/robot_description');
    }
    if (odometry.topic == null) {
      odometry.listen(await caps.pick('nav_msgs/Odometry', 'odom') ?? '$namespace/odom');
    }
    if (!nav.configured) {
      final overrides = await MapTopicStore.loadAt(storeAddress);
      final ros1 = caps.rosVersion == RosVersion.ros1;
      final action = overrides[MapSlot.navAction] ?? (ros1 ? null : caps.actionNamed('navigate_to_pose'));
      // Only a topic that is called goal_pose: any other PoseStamped listener is something else (on a
      // drone it is MAVROS's position setpoint, which would fly the vehicle there).
      final picked = await caps.pick('geometry_msgs/PoseStamped', 'goal_pose', role: TopicRole.write);
      final goal = overrides[MapSlot.goal] ?? (picked != null && picked.endsWith('/goal_pose') ? picked : null);
      if (!nav.configured) {
        // A robot that did not answer discovery may still navigate: only then assume it does.
        nav.configure(version: caps.rosVersion, navigateAction: action, goalTopic: goal,
            moveBaseAction: caps.actionNamed('move_base'),
            found: caps.topics == null || (ros1 && caps.topicNames.any((t) => t.endsWith('move_base/goal')))
                ? true : null);
      }
    }
  }

  /// Stops the base, withdraws the session's topics and stops following goals. Does not close
  /// [connection]; whoever opened it does.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    drive.dispose();
    nav.dispose();
    odometry.dispose();
    places.dispose();
    requests.dispose();
    routines.dispose();
    arm.dispose();
    armPoses.dispose();
    robotLog.dispose();
    ros.dispose();
  }
}
