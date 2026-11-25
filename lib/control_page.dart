import 'app_language.dart';
import 'dart:async';
import 'mini_map.dart';
import 'relay_messages.dart';
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_joystick/flutter_joystick.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'arm.dart';
import 'controllers/arm_controller.dart';
import 'controllers/drive_controller.dart';
import 'controllers/navigation_controller.dart';
import 'disconnect_safety.dart';
import 'drive_command.dart';
import 'package:gamepads/gamepads.dart' show GamepadAxis, GamepadButton;
import 'keyboard_drive.dart';
import 'link_quality.dart';
import 'mjpeg.dart';
import 'drone.dart';
import 'navigation_goal.dart' show RosVersion;
import 'robot_capabilities.dart';
import 'robot_profile.dart';
import 'ros_client.dart';
import 'ros_connection.dart';
import 'ros_image.dart';
import 'widgets/arm_panel.dart';
import 'widgets/control_stick.dart';

/// Landscape driving screen: full-bleed camera with a controller chosen by the robot's drive type.
class ControlScreen extends StatefulWidget {
  final RosConnection channel;
  final String ip;
  final String port;
  final RosConnection Function(String, String) imageConnectionFactory;

  /// The session's shared discovery (see [RobotSession.capabilities]); without it the screen
  /// discovers on its own connection.
  final Future<RobotCapabilities> Function()? capabilities;

  /// The session's drive controller, shared with the AI agent; without it the screen makes its own
  /// and withdraws the command topic when it closes.
  final DriveController? drive;
  /// Game controller events (tests pass their own; the default is every connected controller).
  final Stream<PadEvent> Function() padEvents;
  final NavigationController? navigation;

  /// Which robot on the connection (`/robot1`), '' for a robot at the root. Settings are saved per robot.
  final String namespace;

  /// Where this robot's settings are saved (RobotSession.storeAddress); its address when not given.
  final String? storeAddress;
  String get savedAs => storeAddress ?? '$ip:$port$namespace';

  /// Saved arm postures (shared with the AI assistant); without it the Save pose button is hidden.
  final ArmPoseBook? armPoses;

  const ControlScreen({super.key, required this.ip, required this.port, required this.channel,
    this.imageConnectionFactory = RosConnection.new, this.capabilities, this.drive, this.namespace = '', this.navigation,
    this.padEvents = gamepadEvents,
    this.storeAddress,
    this.armPoses});

  @override
  State<ControlScreen> createState() => ControlScreenState();
}

class ControlScreenState extends State<ControlScreen> with WidgetsBindingObserver {
  RobotProfile? profile; // null until loaded or chosen
  RobotProfile? suggestion;
  bool choosingType = false;
  RosVersion rosVersion = RosVersion.ros2;
  SpeedPreset preset = SpeedPreset.slow;

  StickInput _input = StickInput.zero;
  /// From a keyboard or a game controller's D-pad (see keyboard_drive.dart); the touch sticks win.
  StickInput _keyInput = StickInput.zero;
  /// After STOP, held direction keys are ignored until all are released (as a held stick is).
  bool _keysLatched = false;
  /// A game controller's analog sticks (gamepads package), the same latch after STOP.
  final _padAxes = <GamepadAxis, double>{};
  StickInput _padInput = StickInput.zero;
  bool _padLatched = false;
  StreamSubscription<PadEvent>? _padSubscription;

  void _onPad(PadEvent e) {
    final p = profile;
    if (!mounted || p == null || !p.hasBase || isAerial) return;
    if (e.button == GamepadButton.b && e.value > 0.5) {
      _padInput = StickInput.zero;
      _padLatched = true;
      _emergencyStop();
      return;
    }
    final axis = e.axis;
    if (axis == null) return;
    _padAxes[axis] = e.value;
    final next = padStick(_padAxes);
    if (_padLatched) {
      if (next.isZero) _padLatched = false;
      return;
    }
    if (next.leftX == _padInput.leftX && next.leftY == _padInput.leftY && next.rightX == _padInput.rightX) return;
    _padInput = next;
    if (!next.isZero) {
      drive.automation.interrupt();
      widget.navigation?.cancel();
    }
    _publishTick();
  }
  bool _leftLatched = false, _rightLatched = false; // after STOP, a stick must be released first
  bool _active = true;
  Timer? _heartbeat; // drone setpoint stream (ground driving is timed by [drive])

  /// No picture arrived for a while after the camera was connected.
  bool cameraSlow = false;
  Timer? _cameraSlowTimer;
  RosClient? _ownRos; // only when the screen has no session drive controller
  /// Owns the base's velocity command: STOP, then the sticks, then agent motion.
  /// Round-trip lag to the robot, shown in the top bar when it is slow enough to matter.
  late final LinkQuality link = LinkQuality(drive.ros)..start();
  late final DriveController drive = (widget.drive ?? DriveController(_ownRos = RosClient(widget.channel)))
    ..manualInput = _manualCommand
    ..addListener(_onDrive);

  DriveCommand command = DriveCommand.stop;
  double? odomSpeed, odomYawRate;
  String? controlError, streamError;

  /// The link dropped while the robot was moving (shown as a loud warning, not a normal error).
  bool linkLostMoving = false;

  /// Nothing found on the robot that stops it when commands stop: shown once per robot until dismissed.
  bool showLinkLossNotice = false;
  StreamSubscription? _controlSubscription;
  String odomTopic = '/odom', jointStatesTopic = '/joint_states';
  String _autoOdom = '/odom', _autoJointStates = '/joint_states'; // what discovery found
  String robotDescriptionTopic = '/robot_description';

  RosConnection? _imageChannel;
  StreamSubscription? _imageSubscription;
  ui.Image? image;
  bool _decoding = false;
  /// Set when a raw (uncompressed) camera stream was slowed down to what rosbridge can carry.
  String? cameraNote;
  bool _rawRateChecked = false;
  int _imageGeneration = 0;
  MjpegStream? _mjpeg; // web_video_server
  Player? _rtspPlayer; // libmpv
  VideoController? _rtspVideo;
  final _rtspSubscriptions = <StreamSubscription>[];

  // Arm (arms and mobile manipulators)
  bool armMode = false;
  List<String> jointNames = [];
  Map<String, double> jointPositions = {};
  Map<String, JointLimit> jointLimits = {};
  List<String> _actionServers = [];
  String? _armAdvertised;
  String? _gripperGoalId;
  int _goalSeq = 0;
  DateTime _lastLiveArmSend = DateTime.fromMillisecondsSinceEpoch(0);

  // Drone (MAVROS)
  DroneTelemetry drone = const DroneTelemetry();
  String? _droneNs; // e.g. /mavros, set once subscribed
  DateTime _lastOffboardRequest = DateTime.fromMillisecondsSinceEpoch(0); // retries are spaced out
  DateTime? _sticksCenteredAt; // in OFFBOARD with sticks released: hand over to position hold
  bool _holdRequested = false;
  bool get isAerial => profile?.drive == DriveType.aerial;

  bool get online => !widget.channel.isClosed;
  List<String> get armJointNames => armJoints(jointNames, pinned: profile?.arm?.joints ?? const [],
      urdfOrder: jointLimits.keys.toList());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    try {
      _padSubscription = widget.padEvents().listen(_onPad, onError: (_) {}); // no controller support: nothing
    } catch (_) {}
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controlSubscription = widget.channel.messages.listen((event) {
      if (!mounted) return;
      final refused = statusErrorIn(event, context.strings);
      if (refused != null) setState(() => controlError = refused);
      if (event['topic'] == jointStatesTopic && event['msg'] is Map) {
        final names = List<String>.from(event['msg']['name'] as List? ?? const []);
        final values = (event['msg']['position'] as List? ?? const []).map((v) => (v as num).toDouble()).toList();
        setState(() {
          jointNames = names;
          jointPositions = {for (var i = 0; i < names.length && i < values.length; i++) names[i]: values[i]};
        });
      }
      if (event['topic'] == robotDescriptionTopic && event['msg'] is Map && event['msg']['data'] is String) {
        setState(() => jointLimits = parseJointLimits(event['msg']['data'] as String));
      }
      final ns = _droneNs;
      if (ns != null && event['msg'] is Map) {
        final msg = event['msg'] as Map;
        if (event['topic'] == '$ns/state') {
          setState(() => drone = drone.copyWith(connected: msg['connected'] == true, armed: msg['armed'] == true,
            mode: '${msg['mode'] ?? ''}'));
        } else if (event['topic'] == '$ns/local_position/pose' && msg['pose'] is Map) {
          // Heading only: local z is relative to the EKF origin, which drifts on the ground (home can
          // sit at z = -2 m), so it is not a usable altitude.
          setState(() => drone = drone.copyWith(yaw: yawOf((msg['pose'] as Map)['orientation'] as Map)));
        } else if (event['topic'] == '$ns/global_position/rel_alt' && msg['data'] is num) {
          setState(() => drone = drone.copyWith(altitude: (msg['data'] as num).toDouble())); // above home
        } else if (event['topic'] == '$ns/battery' && msg['percentage'] is num) {
          setState(() => drone = drone.copyWith(battery: (msg['percentage'] as num).toDouble()));
        }
      }
      if (event['topic'] == odomTopic && event['msg'] is Map) {
        final twist = event['msg']['twist']?['twist'];
        if (twist is Map) {
          setState(() {
            odomSpeed = (twist['linear']['x'] as num).toDouble();
            odomYawRate = (twist['angular']['z'] as num).toDouble();
          });
        }
      }
    }, onDone: () {
      if (!mounted) return;
      final moving = lostWhileMoving(lastMotion: drive.lastMotionAt, movingNow: !drive.current.isStop,
          now: DateTime.now());
      if (moving) HapticFeedback.heavyImpact();
      setState(() {
        linkLostMoving = moving;
        controlError = context.strings.robotDisconnectedControl;
      });
    });
    drive; // created now so it is in place before the profile arrives
    _heartbeat = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (isAerial) _publishTick();
    });
    _init();
  }

  RobotCapabilities? _caps;

  Future<void> _init() async {
    final caps = await (widget.capabilities?.call() ?? RobotCapabilities.discover(widget.channel));
    _caps = caps;
    final topics = caps.topics;
    _actionServers = caps.actionServers; // empty on ROS 1 or an older rosapi: no gripper suggestion
    final nodes = caps.nodes;
    if (!mounted) return;
    rosVersion = caps.rosVersion;
    // Pick by type, preferring conventional names, skipping topics nobody publishes on.
    _autoOdom = odomTopic = await caps.pick('nav_msgs/Odometry', 'odom') ?? '${widget.namespace}/odom';
    _autoJointStates = jointStatesTopic =
        await caps.pick('sensor_msgs/JointState', 'joint_states') ?? '${widget.namespace}/joint_states';
    robotDescriptionTopic = await caps.pick('std_msgs/String', 'robot_description') ?? '/robot_description';
    if (!mounted) return;
    _checkLinkLossGuard(caps);
    try { widget.channel.send({'op': 'subscribe', 'topic': odomTopic, 'throttle_rate': 200}); } catch (_) {}
    final stored = await ProfileStore.loadAt(widget.savedAs);
    if (!mounted) return;
    final cameraHost = robotHost(widget.ip);
    final rtsp = Uri(scheme: 'rtsp', host: cameraHost, port: 8554, path: '/test').toString();
    if (stored != null) {
      _apply(stored);
    } else {
      var suggested = suggestProfile(topics, rtspUrl: rtsp, actionServers: _actionServers, nodes: nodes,
          host: cameraHost);
      // A Twist topic nobody subscribes to (e.g. a stale /cmd_vel next to /robot1/cmd_vel) moves nothing.
      if (suggested.drive == DriveType.differential || suggested.drive == DriveType.holonomic) {
        final command = await caps.pickVelocityCommand();
        if (command != null) suggested = suggested.copyWith(commandTopic: command);
      }
      if (!mounted) return;
      setState(() {
        suggestion = suggested;
        choosingType = true;
      });
    }
  }

  String get _noticeKey => 'link_loss_notice_seen:${widget.savedAs}';

  /// Tells the user once per robot when nothing on it is known to stop the base on a lost link.
  Future<void> _checkLinkLossGuard(RobotCapabilities caps) async {
    if (stopOnLinkLossGuard(nodes: caps.nodes, topics: caps.topicNames) != null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_noticeKey) == true || !mounted) return;
      setState(() => showLinkLossNotice = true);
    } catch (_) {}
  }

  void _dismissLinkLossNotice() {
    setState(() => showLinkLossNotice = false);
    SharedPreferences.getInstance().then((p) => p.setBool(_noticeKey, true)).catchError((_) => true);
  }

  /// Switches to [next]: re-advertises the command topic and reconnects the camera if needed.
  void _apply(RobotProfile next, {bool persist = false}) {
    final previous = profile;
    _stop(latch: false);
    // Re-advertises when the command topic or type changes; a TwistStamped topic gets stamped commands.
    drive.configure(next, rosVersion, commandTopicType: _caps?.typeOf(next.commandTopic));
    if (drive.lastError != null) controlError = drive.lastError;
    final cameraChanged = previous == null || previous.cameraSource != next.cameraSource ||
        previous.cameraTopic != next.cameraTopic || previous.rtspUrl != next.rtspUrl ||
        previous.mjpegUrl != next.mjpegUrl;
    _applyTopicOverrides(previous, next);
    _applyArm(previous?.arm, next.arm);
    if (next.drive == DriveType.aerial) _subscribeDrone(mavrosNamespace(next.commandTopic));
    setState(() {
      profile = next;
      choosingType = false;
      armMode = next.arm != null && (!next.hasBase || armMode);
    });
    if (cameraChanged) _connectCamera(next);
    if (persist) ProfileStore.saveAt(widget.savedAs, next);
  }

  /// Switches odometry / joint-state subscriptions to the profile's manual topics (or back to discovery).
  void _applyTopicOverrides(RobotProfile? previous, RobotProfile next) {
    final odom = next.odomTopic.isNotEmpty ? next.odomTopic : _autoOdom;
    if (odom != odomTopic) {
      try {
        widget.channel.send({'op': 'unsubscribe', 'topic': odomTopic});
        widget.channel.send({'op': 'subscribe', 'topic': odom, 'throttle_rate': 200});
      } catch (e) { controlError = '$e'; }
      odomTopic = odom;
      odomSpeed = null;
      odomYawRate = null;
    }
    final joints = next.jointStatesTopic.isNotEmpty ? next.jointStatesTopic : _autoJointStates;
    if (joints != jointStatesTopic) {
      // Arm subscriptions start in _applyArm for a new arm; an existing one is moved here.
      if (previous?.arm != null && next.arm != null) {
        try {
          widget.channel.send({'op': 'unsubscribe', 'topic': jointStatesTopic});
          widget.channel.send({'op': 'subscribe', 'topic': joints, 'throttle_rate': 100, 'queue_length': 1});
        } catch (e) { controlError = '$e'; }
      }
      jointStatesTopic = joints;
    }
  }

  /// Fixed decimals without "-0.00" for values that round to zero (odometry noise at rest).
  static String _fixed(double v, int digits) {
    final text = v.toStringAsFixed(digits);
    return double.parse(text) == 0 ? 0.0.toStringAsFixed(digits) : text;
  }

  // ---- drone ----------------------------------------------------------------------------

  void _subscribeDrone(String ns) {
    if (_droneNs == ns) return;
    _droneNs = ns;
    drone = const DroneTelemetry();
    try {
      widget.channel.send({'op': 'subscribe', 'topic': '$ns/state'});
      widget.channel.send({'op': 'subscribe', 'topic': '$ns/local_position/pose', 'throttle_rate': 100});
      widget.channel.send({'op': 'subscribe', 'topic': '$ns/battery', 'throttle_rate': 1000});
      widget.channel.send({'op': 'subscribe', 'topic': '$ns/global_position/rel_alt', 'throttle_rate': 200});
    } catch (e) {
      controlError = '$e';
    }
  }

  Future<bool> _droneService(String name, Map<String, dynamic> args, String failure) async {
    final ns = _droneNs;
    if (ns == null || !online) return false;
    try {
      final values = await widget.channel.call('$ns/$name', args);
      final ok = values['mode_sent'] == true || values['success'] == true;
      if (!ok && mounted) setState(() => controlError = '$failure (vehicle refused)');
      return ok;
    } catch (e) {
      if (mounted) setState(() => controlError = '$failure: $e');
      return false;
    }
  }

  Future<bool> _setMode(String mode) {
    if (mode == FlightMode.offboard) _lastOffboardRequest = DateTime.now();
    return _droneService('set_mode', setModeArgs(mode), 'Could not switch to $mode');
  }

  Future<void> _takeoff() async {
    HapticFeedback.heavyImpact();
    setState(() => controlError = null);
    if (await _setMode(FlightMode.takeoff)) {
      await _droneService('cmd/arming', armingArgs(true), 'Could not arm');
    }
  }

  Future<void> _hover() async {
    _input = StickInput.zero;
    if (drone.armed) await _setMode(FlightMode.hold);
  }

  // ---- arm ----------------------------------------------------------------------------

  void _applyArm(ArmConfig? previous, ArmConfig? next) {
    if (_armAdvertised != null && _armAdvertised != next?.trajectoryTopic) {
      try { widget.channel.send({'op': 'unadvertise', 'topic': _armAdvertised}); } catch (_) {}
      _armAdvertised = null;
    }
    if (next == null) return;
    try {
      if (_armAdvertised == null) {
        widget.channel.send({'op': 'advertise', 'topic': next.trajectoryTopic,
          'type': 'trajectory_msgs/JointTrajectory'});
        _armAdvertised = next.trajectoryTopic;
      }
      if (previous == null) {
        widget.channel.send({'op': 'subscribe', 'topic': jointStatesTopic, 'throttle_rate': 100, 'queue_length': 1});
        widget.channel.send({'op': 'subscribe', 'topic': robotDescriptionTopic});
      }
    } catch (e) {
      controlError = '$e';
    }
  }

  double get _armSpeed => 1.0 * preset.scale; // rad/s for the largest joint move

  void _sendArm(Map<String, double> targets, {required bool live}) {
    final arm = profile?.arm;
    final joints = armJointNames;
    if (arm == null || joints.isEmpty || !online) return;
    final now = DateTime.now();
    if (live && now.difference(_lastLiveArmSend).inMilliseconds < 150) return; // ~6 Hz while dragging
    _lastLiveArmSend = now;
    final from = [for (final j in joints) jointPositions[j] ?? 0.0];
    final to = [for (final j in joints) (jointLimits[j] ?? fallbackLimit).clamp(targets[j] ?? jointPositions[j] ?? 0.0)];
    try {
      widget.channel.send({'op': 'publish', 'topic': arm.trajectoryTopic,
        'msg': trajectoryMessage(joints, to, moveDuration(from, to, _armSpeed), rosVersion)});
    } catch (e) {
      setState(() => controlError = '$e');
    }
  }

  void _armHome() => _sendArm({for (final j in armJointNames) j: 0.0}, live: false);

  /// Names the arm's current posture, so the AI assistant ("arm to carry") and routines can use it.
  Future<void> _saveArmPose() async {
    final book = widget.armPoses;
    final joints = armJointNames;
    if (book == null || joints.isEmpty) return;
    final here = {for (final j in joints) j: jointPositions[j] ?? 0.0};
    final controller = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (c) => AlertDialog(
      title: Text(context.strings.saveArmPose),
      content: TextField(key: const Key('arm-pose-name'), controller: controller, autofocus: true,
        decoration: InputDecoration(labelText: context.strings.name, hintText: context.strings.armPoseHint),
        onSubmitted: (v) => Navigator.pop(c, v)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('arm-pose-save'), onPressed: () => Navigator.pop(c, controller.text),
          child: Text(context.strings.save)),
      ]));
    controller.dispose();
    if (name == null || name.trim().isEmpty || !mounted) return;
    await book.save(ArmPose(name.trim(), here));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(context.strings.armPoseSaved(name.trim()))));
    }
  }

  void _gripper(bool open) {
    final arm = profile?.arm;
    final joint = gripperJoint(jointNames);
    if (arm == null || arm.gripperAction.isEmpty || !online) return;
    final limit = (joint == null ? null : jointLimits[joint]) ?? const JointLimit(-0.01, 0.019);
    _cancelGripper();
    final id = 'gripper_${++_goalSeq}';
    _gripperGoalId = id;
    try {
      widget.channel.send({'op': 'send_action_goal', 'id': id, 'action': arm.gripperAction,
        'action_type': 'control_msgs/action/GripperCommand', 'feedback': false,
        'args': {'command': {'position': open ? limit.upper : limit.lower, 'max_effort': 1.0}}});
    } catch (e) {
      setState(() => controlError = '$e');
    }
  }

  void _cancelGripper() {
    final arm = profile?.arm;
    final id = _gripperGoalId;
    if (arm == null || id == null) return;
    _gripperGoalId = null;
    try { widget.channel.send({'op': 'cancel_action_goal', 'id': id, 'action': arm.gripperAction}); } catch (_) {}
  }

  /// Holds the arm at its measured position (see holdMessage).
  void _holdArm() {
    final arm = profile?.arm;
    final joints = armJointNames;
    if (arm == null || joints.isEmpty || !online) return;
    try {
      final here = [for (final j in joints) jointPositions[j] ?? 0.0];
      widget.channel.send({'op': 'publish', 'topic': arm.trajectoryTopic, 'msg': holdMessage(joints, here, rosVersion)});
    } catch (_) {}
    _cancelGripper();
  }

  // ---- commands -------------------------------------------------------------------------

  void _onStick(bool left, Offset value) {
    if (left ? _leftLatched : _rightLatched) {
      if (value == Offset.zero) setState(() => left ? _leftLatched = false : _rightLatched = false);
      return;
    }
    _input = left
        ? StickInput(leftX: value.dx, leftY: value.dy, rightX: _input.rightX, rightY: _input.rightY)
        : StickInput(leftX: _input.leftX, leftY: _input.leftY, rightX: value.dx, rightY: value.dy);
    if (!_input.isZero) {
      drive.automation.interrupt();
      widget.navigation?.cancel();
    }
    _publishTick();
  }

  /// Sends the current command now. Ground robots go through [drive], which also repeats it every
  /// 100 ms while a stick is held and sends one stop when everything is released.
  void _publishTick() {
    final current = profile;
    if (current == null || !mounted || !current.hasBase) return;
    if (current.drive == DriveType.aerial) return _droneTick(current);
    drive.tick();
  }

  /// What the sticks ask for, read by [drive] on every tick.
  DriveCommand _manualCommand() {
    final current = profile;
    if (current == null || !_active || current.drive == DriveType.aerial) return DriveCommand.stop;
    // The touch sticks win, then a controller's sticks, then keys.
    return commandFor(current, preset, !_input.isZero ? _input : !_padInput.isZero ? _padInput : _keyInput);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final p = profile;
    if (p == null || !p.hasBase || isAerial || !isDriveKey(event.logicalKey)) return KeyEventResult.ignored;
    // Letters typed into a text field must never drive the robot; a release always counts, so a key let
    // go while a field has focus still stops what it started.
    if (event is! KeyUpEvent && FocusManager.instance.primaryFocus?.context?.widget is EditableText) {
      return KeyEventResult.ignored;
    }
    if (event is KeyDownEvent && isStopKey(event.logicalKey)) {
      _keyInput = StickInput.zero;
      _keysLatched = true;
      _emergencyStop();
      return KeyEventResult.handled;
    }
    final next = keyStick(HardwareKeyboard.instance.logicalKeysPressed);
    if (_keysLatched) {
      if (next.isZero) _keysLatched = false;
      return KeyEventResult.handled;
    }
    if (next.leftX == _keyInput.leftX && next.leftY == _keyInput.leftY && next.rightX == _keyInput.rightX) {
      return KeyEventResult.handled;
    }
    _keyInput = next;
    if (!next.isZero) {
      drive.automation.interrupt();
      widget.navigation?.cancel();
    }
    _publishTick();
    return KeyEventResult.handled;
  }

  void _onDrive() {
    if (!mounted || isAerial) return;
    setState(() {
      command = drive.current;
      if (drive.lastError != null) controlError = drive.lastError;
    });
  }

  /// While armed, a velocity setpoint is streamed every tick (zero = hover): PX4 needs a steady
  /// stream to enter and stay in OFFBOARD, and falls back to its own failsafe if the stream stops.
  void _droneTick(RobotProfile current) {
    if (!drone.armed) {
      if (!command.isStop) setState(() => command = DriveCommand.stop);
      return;
    }
    final next = _active ? droneSetpoint(current, preset, _input, drone.yaw ?? 0) : DriveCommand.stop;
    _send(current, next);
    final wantsControl = !_input.isZero && _active;
    final now = DateTime.now();
    if (wantsControl) {
      _sticksCenteredAt = null;
      _holdRequested = false;
      if (!drone.offboard && now.difference(_lastOffboardRequest).inMilliseconds > 1500) {
        _setMode(FlightMode.offboard); // touching the sticks takes manual control
      }
    } else if (drone.offboard) {
      // A zero velocity setpoint only stops; it does not hold position (measured ~0.3 m/s drift in
      // SITL). After a short braking period, let PX4 hold the position like a centred RC stick.
      _sticksCenteredAt ??= now;
      if (!_holdRequested && now.difference(_sticksCenteredAt!).inMilliseconds > 600) {
        _holdRequested = true;
        _setMode(FlightMode.hold);
      }
    }
    setState(() => command = next);
  }

  void _send(RobotProfile current, DriveCommand next) {
    if (!online || !current.hasBase) return;
    drive.sendNow(next);
    if (drive.lastError != null) controlError = drive.lastError;
  }

  /// Zero velocity now. With [latch], sticks that were deflected are ignored until released
  /// (an untouched stick stays usable).
  void _stop({bool latch = true}) {
    final current = profile;
    if (latch) {
      if (_input.leftX != 0 || _input.leftY != 0) _leftLatched = true;
      if (_input.rightX != 0 || _input.rightY != 0) _rightLatched = true;
    }
    _input = StickInput.zero;
    _keyInput = StickInput.zero;
    _padInput = StickInput.zero;
    if (current != null && online) drive.stop();
    if (mounted) setState(() => command = DriveCommand.stop);
  }

  void _emergencyStop() {
    HapticFeedback.heavyImpact();
    drive.automation.interrupt();
    widget.navigation?.cancel();
    _stop();
    _holdArm();
    if (isAerial) _hover(); // a drone must never cut motors in the air: HOLD hovers in place
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _stop();
      _holdArm();
      if (isAerial && drone.offboard) _hover();
    }
  }

  // ---- camera ---------------------------------------------------------------------------

  void _connectCamera(RobotProfile p) {
    final generation = ++_imageGeneration;
    cameraSlow = false;
    _cameraSlowTimer?.cancel();
    if (p.cameraSource != CameraSource.none) {
      _cameraSlowTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && generation == _imageGeneration && image == null) setState(() => cameraSlow = true);
      });
    }
    _imageSubscription?.cancel();
    _imageSubscription = null;
    _imageChannel?.close();
    _imageChannel = null;
    _closeRtsp();
    _mjpeg?.stop();
    _mjpeg = null;
    final previousImage = image;
    image = null;
    streamError = null;
    WidgetsBinding.instance.addPostFrameCallback((_) => previousImage?.dispose());
    if (p.cameraSource == CameraSource.rtsp && p.rtspUrl.isNotEmpty) {
      _openRtsp(p.rtspUrl);
    } else if (p.cameraSource == CameraSource.mjpeg && p.mjpegUrl.isNotEmpty) {
      _openMjpeg(p.mjpegUrl, generation);
    } else if (p.cameraSource == CameraSource.rosImage) {
      _subscribeImage(p.cameraTopic, generation);
    }
    if (mounted) setState(() {});
  }

  /// RTSP over TCP (robust through Wi-Fi/NAT) with mpv's low-latency profile; errors go to the banner.
  void _openRtsp(String url) {
    final player = Player();
    _rtspPlayer = player;
    // Android: decode with MediaCodec straight into the video surface (no mpv OpenGL context; that
    // context could not be created on the emulator, and MediaCodec also saves battery on phones).
    _rtspVideo = VideoController(player, configuration: const VideoControllerConfiguration(
        vo: 'mediacodec_embed', hwdec: 'mediacodec'));
    final native = player.platform;
    if (native is NativePlayer) {
      // Low latency without mpv's "low-latency" profile: that profile skips stream probing, so the
      // decoder is configured as 0x0 and Android's MediaCodec refuses it (black video).
      for (final (key, value) in [('rtsp-transport', 'tcp'), ('cache', 'no'), ('demuxer-lavf-o', 'fflags=+nobuffer'),
          ('video-latency-hacks', 'yes')]) {
        // Called dynamically: the web build's NativePlayer stub has no setProperty (and is never used there).
        unawaited(((native as dynamic).setProperty(key, value) as Future<void>).catchError((Object _) {}));
      }
    }
    _rtspSubscriptions
      // mpv also reports harmless messages (e.g. "Cannot seek in this stream") as errors: only surface
      // them while no picture has arrived yet.
      ..add(player.stream.error.listen((e) {
        if (mounted && (player.state.width ?? 0) == 0) setState(() => streamError = 'RTSP: $e');
      }))
      ..add(player.stream.width.listen((w) { if (mounted && (w ?? 0) > 0) setState(() => streamError = null); }));
    unawaited(player.open(Media(url)).catchError((Object e) { if (mounted) setState(() => streamError = 'RTSP: $e'); }));
  }

  /// MJPEG over HTTP (web_video_server): frames are decoded like CompressedImage; a frame that arrives
  /// while the previous one is still decoding is dropped, so latency never builds up.
  void _openMjpeg(String url, int generation) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      streamError = 'Invalid MJPEG URL: $url';
      return;
    }
    _mjpeg = MjpegStream(uri, onFrame: (jpeg) {
      if (!mounted || generation != _imageGeneration || _decoding) return;
      _decoding = true;
      decodeCompressedImage({'format': 'jpeg', 'data': jpeg}).then((decoded) {
        _decoding = false;
        if (!mounted || generation != _imageGeneration) { decoded.dispose(); return; }
        final previous = image;
        setState(() { image = decoded; streamError = null; });
        WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
      }, onError: (Object e) { _decoding = false; });
    }, onError: (e) {
      if (mounted && generation == _imageGeneration) setState(() => streamError = 'MJPEG: $e (retrying)');
    })..start();
  }

  void _closeRtsp() {
    for (final s in _rtspSubscriptions) {
      s.cancel();
    }
    _rtspSubscriptions.clear();
    final player = _rtspPlayer;
    _rtspPlayer = null;
    _rtspVideo = null;
    if (player != null) unawaited(player.dispose().catchError((Object _) {}));
  }

  Future<void> _subscribeImage(String topic, int generation) async {
    try {
      final client = widget.imageConnectionFactory(widget.ip, widget.port);
      _imageChannel = client;
      _imageSubscription = client.messages.listen((event) {
        if (mounted && generation == _imageGeneration && event['level'] == 'error') {
          setState(() => streamError = '${event['msg']}');
          return;
        }
        if (!mounted || generation != _imageGeneration || _decoding || event['topic'] != topic) return;
        final msg = event['msg'];
        if (msg is! Map) return;
        void show(ui.Image decoded) {
          _decoding = false;
          if (!mounted || generation != _imageGeneration) { decoded.dispose(); return; }
          final previous = image;
          setState(() { image = decoded; streamError = null; });
          WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
        }
        if (!_rawRateChecked) {
          _rawRateChecked = true;
          if (!isCompressedImage(msg)) _limitRawRate(client, topic, msg);
        }
        try {
          _decoding = true; // drop frames that arrive while one is still decoding
          if (isCompressedImage(msg)) {
            // sensor_msgs/CompressedImage (JPEG/PNG): ~30x less bandwidth than raw over rosbridge.
            decodeCompressedImage(msg).then(show, onError: (Object e) {
              _decoding = false;
              if (mounted) setState(() => streamError = '$e');
            });
          } else {
            final frame = decodeRosImage(msg);
            ui.decodeImageFromPixels(frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888, show);
          }
        } catch (e) {
          _decoding = false;
          if (mounted) setState(() => streamError = '$e');
        }
      }, onDone: () {
        if (mounted && generation == _imageGeneration) setState(() => streamError = client.lastError);
      });
      await client.ready;
      if (!mounted || generation != _imageGeneration) { client.close(); return; }
      _rawRateChecked = false;
      if (mounted) setState(() => cameraNote = null);
      client.send({'op': 'subscribe', 'id': _cameraSubscription, 'topic': topic, 'throttle_rate': 100,
        'queue_length': 1});
    } catch (e) {
      if (mounted && generation == _imageGeneration) setState(() => streamError = '$e');
    }
  }

  static const _cameraSubscription = 'mobile_ros_camera';
  /// What rosbridge's JSON can carry to a phone without frames queueing up (base64 text per second).
  static const _rawBudgetBytesPerSecond = 1500000;

  /// Uncompressed images are large in rosbridge's JSON (640x480 RGB is ~1.2 MB per frame as base64). If
  /// the phone cannot parse them as fast as they arrive, rosbridge queues them and the picture falls
  /// further and further behind the robot. Sizing the throttle from the first frame keeps it live.
  void _limitRawRate(RosConnection client, String topic, Map msg) {
    final data = msg['data'];
    final bytes = data is String ? data.length : data is List ? data.length : 0;
    final interval = (bytes * 1000 / _rawBudgetBytesPerSecond).round().clamp(100, 2000);
    if (interval <= 100) return;
    try {
      client.send({'op': 'unsubscribe', 'id': _cameraSubscription, 'topic': topic});
      client.send({'op': 'subscribe', 'id': _cameraSubscription, 'topic': topic, 'throttle_rate': interval,
        'queue_length': 1});
    } catch (_) {}
    if (mounted) {
      setState(() => cameraNote = context.strings.uncompressedCamera((1000 / interval).toStringAsFixed(1)));
    }
  }

  // ---- UI -------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final p = profile;
    final compactCamera = MediaQuery.sizeOf(context).height < 400;
    return Focus(autofocus: true, onKeyEvent: _onKey, child: Scaffold(
      backgroundColor: const Color(0xFF0B1620),
      body: Stack(fit: StackFit.expand, children: [
        _cameraLayer(p, showPlaceholder: !compactCamera),
        const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000), Color(0x00000000), Color(0xB3000000)],
          stops: [0, 0.22, 0.62, 1]))),
        SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 12), child: Column(children: [
          _topBar(p),
          // Notices between the top bar and the controls; they scroll rather than push the controls off
          // a small screen.
          Expanded(child: LayoutBuilder(builder: (context, box) => Stack(children: [
          // Where the robot is, while driving by the camera (only when the robot has a map).
          if (p != null && p.hasBase) Positioned(top: 8, right: 0, child: MiniMap(connection: widget.channel,
            capabilities: widget.capabilities, namespace: widget.namespace, maxSide: box.maxHeight - 16)),
          Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (linkLostMoving)
              _linkLostWarning()
            else if (controlError != null)
              _banner(controlError!),
            // Driving works without a picture; the way to fix the camera is one tap away (up here, where
            // it can be tapped, not under the sticks).
            if (p != null && image == null && p.cameraSource != CameraSource.none && (streamError != null || cameraSlow))
              Padding(padding: const EdgeInsets.only(top: 6), child: _pill(Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.videocam_off_outlined, color: Color(0xFF8DA2B3), size: 18),
                const SizedBox(width: 8),
                Flexible(child: Text(streamError != null ? 'Camera: $streamError' : context.strings.noCameraPicture,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12))),
                TextButton(key: const Key('camera-settings'), onPressed: () => _openSettings(p),
                  style: TextButton.styleFrom(foregroundColor: const Color(0xFF78E0CE)),
                  child: Text(context.strings.chooseCamera)),
              ]))),
            if (showLinkLossNotice && !linkLostMoving && p != null && p.hasBase) _linkLossNotice(),
            // Another driver (not this app's own navigation goal): say so before the commands fight.
            if (drive.otherDriving && !(widget.navigation?.isActive ?? false) && p != null && p.hasBase)
              Padding(key: const Key('other-driver'), padding: const EdgeInsets.only(top: 6), child: Text(
                context.strings.otherDriver, maxLines: 3, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFFFC857), fontSize: 12, fontWeight: FontWeight.w700))),
            if (compactCamera && p != null && image == null && _rtspVideo == null &&
                streamError == null && !cameraSlow)
              Padding(padding: const EdgeInsets.only(top: 6), child: _cameraStatus(p)),
          ]))),
          ]))),
          if (p != null && armMode) Align(alignment: Alignment.bottomRight, child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.75),
            child: ArmPanel(
              joints: armJointNames, positions: jointPositions, limits: jointLimits,
              enabled: online && !choosingType, onTarget: _sendArm, onHome: _armHome,
              onSavePose: widget.armPoses == null ? null : _saveArmPose,
              onGripper: (p.arm?.gripperAction.isNotEmpty ?? false) && rosVersion == RosVersion.ros2 ? _gripper : null,
            ))),
          if (p != null && !armMode) _controls(p),
        ]))),
        if (choosingType && suggestion != null) _typePicker(suggestion!),
      ]),
    ));
  }

  Widget _cameraLayer(RobotProfile? p, {required bool showPlaceholder}) {
    if (p?.cameraSource == CameraSource.rtsp && _rtspVideo != null) {
      return Video(key: ValueKey(_rtspVideo), controller: _rtspVideo!, controls: NoVideoControls,
        fit: BoxFit.contain, fill: const Color(0xFF0B1620));
    }
    if (image != null) return _withCameraNote(RawImage(key: const Key('camera-image'), image: image, fit: BoxFit.contain));
    if (p == null || !showPlaceholder) return const SizedBox.expand();
    return _withCameraNote(Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.videocam_off_outlined, color: Color(0xFF5D7385), size: 36),
        const SizedBox(height: 10),
        _cameraStatus(p),
      ]))));
  }

  Widget _cameraStatus(RobotProfile p) {
    final l = context.strings;
    final text = p.cameraSource == CameraSource.none ? l.noCamera
        : streamError != null ? l.cameraUnavailable
        : cameraSlow ? l.noPictureFrom(switch (p.cameraSource) {
          CameraSource.rtsp => 'the RTSP stream',
          CameraSource.mjpeg => 'the MJPEG stream',
          _ => p.cameraTopic,
        }) : l.waitingCamera;
    return Text(text, key: const Key('camera-state'), textAlign: TextAlign.center,
      style: const TextStyle(color: Color(0xFF8DA2B3)));
  }

  /// Shows [cameraNote] (e.g. a slowed-down raw stream) over the camera picture.
  Widget _withCameraNote(Widget picture) {
    final note = cameraNote;
    if (note == null) return picture;
    return Stack(fit: StackFit.expand, children: [
      picture,
      Align(alignment: Alignment.topCenter, child: Padding(
        padding: const EdgeInsets.only(top: 76),
        child: Container(
          key: const Key('camera-note'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: const Color(0xCC0B1620), borderRadius: BorderRadius.circular(12)),
          child: Text(note, style: const TextStyle(color: Color(0xFFB0C2CF), fontSize: 12)),
        ),
      )),
    ]);
  }

  String _speedLabel(SpeedPreset speed) => switch (speed) {
    SpeedPreset.slow => context.strings.slow,
    SpeedPreset.normal => context.strings.normal,
    SpeedPreset.fast => context.strings.fast,
  };

  Widget _lagChip() => ListenableBuilder(listenable: link, builder: (context, _) {
    final ms = link.lagMs;
    if (ms == null || ms < LinkQuality.slowMs) return const SizedBox.shrink();
    final color = ms >= LinkQuality.verySlowMs ? const Color(0xFFFF6B6B) : const Color(0xFFFFC857);
    return Tooltip(message: context.strings.lagHelp(ms), triggerMode: TooltipTriggerMode.tap,
      child: Padding(key: const Key('drive-lag'), padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.network_check, color: color, size: 16),
          const SizedBox(width: 2),
          Text(context.strings.lagMs(ms), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
        ])));
  });

  Widget _topBar(RobotProfile? p) {
    return Row(children: [
      IconButton(tooltip: context.strings.back, color: Colors.white, icon: const Icon(Icons.arrow_back),
        onPressed: () => Navigator.maybePop(context)),
      _lagChip(),
      // The type label gives way first on narrow screens; STOP and presets always stay visible.
      if (p != null) Flexible(flex: 3, child: _pill(Row(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(message: '${_typeName(p.drive)} · ${p.commandTopic}',
          child: Icon(_typeIcon(p.drive), color: const Color(0xFF78E0CE), size: 18)),
        // With the Drive/Arm toggle in the bar there is no room for text; the tooltip keeps it.
        if (!(p.arm != null && p.hasBase)) ...[
          const SizedBox(width: 8),
          Flexible(child: Text(p.hasBase ? '${_typeName(p.drive)} · ${p.commandTopic}' : _typeName(p.drive),
            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 13))),
        ],
      ]))),
      const SizedBox(width: 8),
      Icon(online ? Icons.wifi : Icons.wifi_off, size: 18, color: online ? const Color(0xFF78E0CE) : const Color(0xFFFF8A80)),
      if (p != null && p.arm != null && p.hasBase) Padding(padding: const EdgeInsets.only(left: 8), child: SegmentedButton<bool>(
        key: const Key('mode-toggle'),
        style: SegmentedButton.styleFrom(foregroundColor: Colors.white, selectedForegroundColor: Colors.black,
          selectedBackgroundColor: const Color(0xFF78E0CE), visualDensity: VisualDensity.compact),
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: false, label: Text(context.strings.drive), icon: const Icon(Icons.sports_esports_outlined, size: 16)),
          ButtonSegment(value: true, label: Text(context.strings.arm), icon: const Icon(Icons.precision_manufacturing_outlined, size: 16)),
        ],
        selected: {armMode},
        onSelectionChanged: (s) {
          _stop(latch: false); // never leave the base moving when switching to the arm
          setState(() => armMode = s.first);
        },
      )),
      const Spacer(),
      if (p != null && (MediaQuery.sizeOf(context).width < 800 || MediaQuery.textScalerOf(context).scale(12) > 16))
        PopupMenuButton<SpeedPreset>(
          tooltip: context.strings.speedPreset, initialValue: preset,
          onSelected: (value) { HapticFeedback.selectionClick(); setState(() => preset = value); },
          itemBuilder: (_) => [for (final speed in SpeedPreset.values)
            PopupMenuItem(value: speed, child: Text(_speedLabel(speed)))],
          // Looks like a control: the speed icon, the current preset and a drop-down mark.
          child: _pill(Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.speed, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(_speedLabel(preset), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            const Icon(Icons.arrow_drop_down, color: Colors.white),
          ])),
        )
      else if (p != null) _pill(Row(mainAxisSize: MainAxisSize.min, children: [
        for (final s in SpeedPreset.values) Padding(padding: const EdgeInsets.symmetric(horizontal: 1),
          child: ChoiceChip(
            key: Key('preset-${s.name}'), label: Text(_speedLabel(s), style: const TextStyle(fontSize: 12)),
            selected: preset == s, visualDensity: VisualDensity.compact, showCheckmark: false,
            labelPadding: const EdgeInsets.symmetric(horizontal: 4),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onSelected: (_) { HapticFeedback.selectionClick(); setState(() => preset = s); },
          )),
      ])),
      IconButton(key: const Key('control-settings'), tooltip: context.strings.robotSettings, color: Colors.white,
        icon: const Icon(Icons.tune), onPressed: p == null ? null : () => _openSettings(p)),
      const SizedBox(width: 4),
      FilledButton.icon(
        key: const Key('estop'),
        style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white,
          minimumSize: const Size(104, 52), padding: const EdgeInsets.symmetric(horizontal: 16)),
        onPressed: online ? _emergencyStop : null,
        icon: Icon(p?.drive == DriveType.aerial ? Icons.pause_circle_outline : Icons.pan_tool),
        label: Text(p?.drive == DriveType.aerial ? context.strings.hold : context.strings.stop),
      ),
    ]);
  }

  Widget _controls(RobotProfile p) {
    final enabled = online && !choosingType;
    final compact = MediaQuery.sizeOf(context).height < 400;
    final stickSize = compact ? 140.0 : 168.0;
    final (leftMode, leftLabel, rightLabel) = switch (p.drive) {
      DriveType.differential => (JoystickMode.vertical, context.strings.drive, context.strings.turn),
      DriveType.holonomic => (JoystickMode.all, context.strings.move, context.strings.rotate),
      DriveType.ackermann => (JoystickMode.vertical, context.strings.throttle, context.strings.steer),
      DriveType.none => (JoystickMode.vertical, context.strings.drive, context.strings.turn), // never shown: no base means arm mode
      DriveType.aerial => (JoystickMode.all, context.strings.climbYaw, context.strings.move),
    };
    final aerial = p.drive == DriveType.aerial;
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      _stickWithLabel(ControlStick(key: const Key('stick-left'), mode: leftMode,
        size: stickSize,
        enabled: enabled && (p.drive != DriveType.aerial || drone.armed),
        label: context.strings.stickLabel(leftLabel), onChanged: (v) => _onStick(true, v)), leftLabel, _leftLatched),
      Expanded(child: Center(child: aerial ? _flightPanel() : _readout(p))),
      _stickWithLabel(ControlStick(key: const Key('stick-right'),
        size: stickSize,
        mode: aerial ? JoystickMode.all : JoystickMode.horizontal, enabled: enabled && (!aerial || drone.armed),
        label: context.strings.stickLabel(rightLabel), onChanged: (v) => _onStick(false, v)), rightLabel, _rightLatched),
    ]);
  }

  Widget _stickWithLabel(ControlStick stick, String label, bool latched) => Column(mainAxisSize: MainAxisSize.min, children: [
    stick,
    const SizedBox(height: 6),
    SizedBox(width: stick.size, child: Text(latched ? context.strings.shortRelease : label,
      semanticsLabel: latched ? context.strings.releaseToRearm : null, textAlign: TextAlign.center,
      style: TextStyle(color: latched ? const Color(0xFFFFCC80) : Colors.white70, fontSize: 12, letterSpacing: 0.6))),
  ]);

  Widget _flightPanel() {
    final d = drone;
    final status = !d.connected ? 'NO FLIGHT CONTROLLER'
        : '${d.armed ? 'ARMED' : 'DISARMED'} · ${d.mode.isEmpty ? '—' : d.mode}';
    final buttonStyle = FilledButton.styleFrom(visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 12));
    return _pill(Column(mainAxisSize: MainAxisSize.min, children: [
      Text(status, key: const Key('flight-status'), style: TextStyle(
        color: !d.connected ? const Color(0xFFFF8A80) : d.armed ? const Color(0xFFFFCC80) : Colors.white70,
        fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.1)),
      const SizedBox(height: 2),
      Text('ALT ${d.altitude?.toStringAsFixed(1) ?? '—'} m'
        '${d.battery != null && d.battery! >= 0 ? '  ·  BAT ${(d.battery! * 100).round()}%' : ''}',
        key: const Key('flight-telemetry'),
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      if (d.armed) Text('${command.linearX.toStringAsFixed(1)} / ${command.linearY.toStringAsFixed(1)} / '
        '${command.linearZ.toStringAsFixed(1)} m/s', style: const TextStyle(color: Color(0xFF78E0CE), fontSize: 11)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
        if (!d.armed) Tooltip(message: context.strings.holdToTakeOff,
          child: GestureDetector(
            key: const Key('drone-takeoff'),
            onLongPress: d.connected && online ? _takeoff : null,
            child: FilledButton.icon(style: buttonStyle, onPressed: d.connected && online ? () {
                setState(() => controlError = context.strings.holdToTakeOff);
              } : null,
              icon: const Icon(Icons.flight_takeoff, size: 18), label: Text(context.strings.holdTakeOffButton)),
          )),
        if (d.armed) ...[
          FilledButton.tonalIcon(key: const Key('drone-land'), style: buttonStyle,
            onPressed: online ? () => _setMode(FlightMode.land) : null,
            icon: const Icon(Icons.flight_land, size: 18), label: Text(context.strings.land)),
          FilledButton.tonalIcon(key: const Key('drone-rtl'), style: buttonStyle,
            onPressed: online ? () => _setMode(FlightMode.returnHome) : null,
            icon: const Icon(Icons.home_outlined, size: 18), label: Text(context.strings.returnHome)),
        ],
      ]),
    ]));
  }

  Widget _readout(RobotProfile p) {
    final cmd = p.drive == DriveType.ackermann
        ? '${_fixed(command.linearX, 2)} m/s  ·  steer ${_fixed((command.steering * 57.2958), 0)}°'
        : p.drive == DriveType.holonomic
            ? '${_fixed(command.linearX, 2)} / ${_fixed(command.linearY, 2)} m/s  ·  '
              '${_fixed(command.angularZ, 2)} rad/s'
            : '${_fixed(command.linearX, 2)} m/s  ·  ${_fixed(command.angularZ, 2)} rad/s';
    return _pill(Column(mainAxisSize: MainAxisSize.min, children: [
      Text(context.strings.command, style: const TextStyle(color: Colors.white54, fontSize: 10, letterSpacing: 1.2)),
      Text(cmd, key: const Key('cmd-readout'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
      if (odomSpeed != null) ...[
        const SizedBox(height: 4),
        Text('${context.strings.actual}  ${_fixed(odomSpeed!, 2)} m/s  ·  ${_fixed(odomYawRate!, 2)} rad/s',
          key: const Key('odom-readout'), style: const TextStyle(color: Color(0xFF78E0CE), fontSize: 12)),
      ],
    ]));
  }

  Widget _pill(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: const Color(0x99101C26), borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0x33FFFFFF))),
    child: child,
  );

  Widget _linkLostWarning() => Padding(padding: const EdgeInsets.only(top: 6), child: Container(
    key: const Key('link-lost-warning'),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(color: const Color(0xE6B71C1C), borderRadius: BorderRadius.circular(14)),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 26),
      const SizedBox(width: 10),
      Flexible(child: Text(context.strings.linkLossMoving,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 13))),
    ]),
  ));

  /// A small chip over the camera, once per robot; tapping it explains, and "Got it" puts it away.
  Widget _linkLossNotice() => Padding(padding: const EdgeInsets.only(top: 6), child: GestureDetector(
    key: const Key('link-loss-notice'),
    onTap: () => showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.connectionDropTitle),
      content: SingleChildScrollView(child: Text(context.strings.linkLossNotice)),
      actions: [TextButton(onPressed: () {
        Navigator.pop(context);
        _dismissLinkLossNotice();
      }, child: Text(context.strings.gotIt))],
    )),
    child: _pill(Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.shield_outlined, color: Color(0xFFFFD180), size: 16),
      const SizedBox(width: 6),
      Flexible(child: Text(context.strings.noAutoStop,
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))),
    ]))));

  Widget _banner(String text) => Padding(padding: const EdgeInsets.only(top: 6), child: _pill(Row(
    mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.error_outline, color: Color(0xFFFF8A80), size: 18),
      const SizedBox(width: 8),
      Flexible(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 12))),
    ])));

  static IconData _typeIcon(DriveType d) => switch (d) {
    DriveType.differential => Icons.rotate_right,
    DriveType.holonomic => Icons.open_with,
    DriveType.ackermann => Icons.directions_car_outlined,
    DriveType.none => Icons.precision_manufacturing_outlined,
    DriveType.aerial => Icons.flight,
  };

  String _typeName(DriveType d) => switch (d) {
    DriveType.differential => context.strings.typeDiff,
    DriveType.holonomic => context.strings.typeOmni,
    DriveType.ackermann => context.strings.typeCar,
    DriveType.none => context.strings.typeArm,
    DriveType.aerial => context.strings.typeDrone,
  };

  String _typeHint(DriveType d) => switch (d) {
    DriveType.differential => context.strings.hintDiff,
    DriveType.holonomic => context.strings.hintOmni,
    DriveType.ackermann => context.strings.hintCar,
    DriveType.none => context.strings.hintArm,
    DriveType.aerial => context.strings.hintDrone,
  };

  Widget _typePicker(RobotProfile suggested) {
    var selected = suggested.drive;
    return Container(color: const Color(0xE60B1620), child: SafeArea(child: Center(child: StatefulBuilder(
      builder: (context, setLocal) => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 960),
        child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(context.strings.howRobotMoves, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          // The topics stay as they are; only the frame is translated.
          Text('${context.strings.suggestedFrom([
              '${_typeName(suggested.drive)}${suggested.hasBase ? ' · ${suggested.commandTopic}' : ''}',
              if (suggested.arm != null) '${context.strings.robotArm} · ${suggested.arm!.trajectoryTopic}',
              if (suggested.arm?.gripperAction.isNotEmpty == true) context.strings.gripper,
            ].join(', '))} ${context.strings.changeLater}', textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFB0C2CF))),
          const SizedBox(height: 18),
          // Equal-height cards (IntrinsicHeight + stretch) however long each hint is.
          IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final d in DriveType.values) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4),
              child: InkWell(
                key: Key('type-${d.name}'), borderRadius: BorderRadius.circular(16),
                onTap: () => setLocal(() => selected = d),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: selected == d ? const Color(0xFF0E3B44) : const Color(0xFF16242F),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: selected == d ? const Color(0xFF4FD1C5) : const Color(0x33FFFFFF), width: 2)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Wrap, not Row: five cards get narrow on a phone, so the badge drops below the icon.
                    Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Icon(_typeIcon(d), color: const Color(0xFF78E0CE)),
                      if (d == suggested.drive) Text(context.strings.suggested, style: const TextStyle(color: Color(0xFF78E0CE),
                        fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
                    ]),
                    const SizedBox(height: 10),
                    // Long names ("Omnidirectional") shrink to one line instead of breaking mid-word.
                    FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
                      child: Text(_typeName(d), maxLines: 1,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
                    const SizedBox(height: 4),
                    Text(_typeHint(d), style: const TextStyle(color: Color(0xFFB0C2CF), fontSize: 12, height: 1.35)),
                  ]),
                ),
              ))),
          ])),
          const SizedBox(height: 18),
          FilledButton(
            key: const Key('profile-continue'),
            onPressed: () {
              final base = selected == suggested.drive ? suggested : RobotProfile.defaults(selected,
                commandTopic: selected == DriveType.ackermann || selected == DriveType.aerial
                    || suggested.drive == DriveType.aerial ? null : suggested.commandTopic,
                cameraTopic: suggested.cameraSource == CameraSource.rosImage ? suggested.cameraTopic : null,
                rtspUrl: suggested.rtspUrl, arm: suggested.arm);
              _apply(base, persist: true);
            },
            child: Text(switch (selected) {
              DriveType.aerial => context.strings.startFlying,
              DriveType.none => context.strings.start,
              _ => context.strings.startDriving,
            }),
          ),
        ])),
      ),
    ))));
  }

  Future<void> _openSettings(RobotProfile current) async {
    _stop(latch: false);
    final result = await showDialog<RobotProfile>(context: context,
      builder: (_) => _ProfileDialog(initial: current, typeName: _typeName, host: robotHost(widget.ip),
          autoOdom: _autoOdom, autoJointStates: _autoJointStates));
    if (result != null && mounted) _apply(result, persist: true);
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _cameraSlowTimer?.cancel();
    link.dispose();
    _padSubscription?.cancel();
    drive.removeListener(_onDrive);
    drive.manualInput = () => DriveCommand.stop;
    if (widget.drive == null) {
      drive.dispose(); // sends a stop and withdraws the command topic
      _ownRos?.dispose();
    } else if (online) {
      drive.stop(); // leaving the screen stops the base; the session keeps the topic for the agent
    }
    _holdArm();
    final ns = _droneNs;
    if (ns != null) {
      if (drone.armed && drone.offboard) {
        // Leaving the screen stops the setpoint stream: hand over to HOLD instead of a failsafe.
        try { widget.channel.send({'op': 'call_service', 'id': 'leave_hold', 'service': '$ns/set_mode',
          'args': setModeArgs(FlightMode.hold)}); } catch (_) {}
      }
      for (final t in ['$ns/state', '$ns/local_position/pose', '$ns/battery', '$ns/global_position/rel_alt']) {
        try { widget.channel.send({'op': 'unsubscribe', 'topic': t}); } catch (_) {}
      }
    }
    if (_armAdvertised != null) {
      try { widget.channel.send({'op': 'unadvertise', 'topic': _armAdvertised}); } catch (_) {}
    }
    for (final topic in [odomTopic, if (profile?.arm != null) ...[jointStatesTopic, robotDescriptionTopic]]) {
      try { widget.channel.send({'op': 'unsubscribe', 'topic': topic}); } catch (_) {}
    }
    _controlSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    ++_imageGeneration;
    image?.dispose();
    _imageSubscription?.cancel();
    _imageChannel?.close();
    _closeRtsp();
    _mjpeg?.stop();
    SystemChrome.setPreferredOrientations([]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }
}

class _ProfileDialog extends StatefulWidget {
  const _ProfileDialog({required this.initial, required this.typeName, required this.host,
    this.autoOdom = '/odom', this.autoJointStates = '/joint_states'});
  final RobotProfile initial;
  final String Function(DriveType) typeName;
  final String host;
  final String autoOdom, autoJointStates;

  @override
  State<_ProfileDialog> createState() => _ProfileDialogState();
}

class _ProfileDialogState extends State<_ProfileDialog> {
  final _form = GlobalKey<FormState>();
  late RobotProfile p = widget.initial;
  late final _topic = TextEditingController(text: p.commandTopic);
  late final _camera = TextEditingController(text: p.cameraTopic);
  late final _rtsp = TextEditingController(text: p.rtspUrl);
  late final _mjpeg = TextEditingController(
      text: p.mjpegUrl.isNotEmpty ? p.mjpegUrl : webVideoServerUrl(widget.host, p.cameraTopic));
  late bool _armEnabled = p.arm != null;
  late final _trajectory = TextEditingController(text: p.arm?.trajectoryTopic ?? '/arm_controller/joint_trajectory');
  late final _gripperAction = TextEditingController(text: p.arm?.gripperAction ?? '');
  late final _odom = TextEditingController(text: p.odomTopic);
  late final _jointStates = TextEditingController(text: p.jointStatesTopic);

  /// Empty is allowed (automatic); otherwise a topic name.
  String? _optionalTopicError(String? v) => (v?.trim() ?? '').isEmpty ? null : _topicError(v);

  String? _topicError(String? v) {
    final t = v?.trim() ?? '';
    return t.isEmpty || !t.startsWith('/') || t.contains(RegExp(r'\s')) ? context.strings.enterTopic : null;
  }

  @override
  void dispose() {
    _topic.dispose(); _camera.dispose(); _rtsp.dispose(); _mjpeg.dispose(); _trajectory.dispose(); _gripperAction.dispose();
    _odom.dispose(); _jointStates.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(context.strings.robotSettings),
      content: SizedBox(width: 560, child: Form(key: _form, child: SingleChildScrollView(
        // Room above the first field, or its floating label is clipped by the scroll view.
        padding: const EdgeInsets.only(top: 8),
        child: Column(
        mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DropdownButtonFormField<DriveType>(
            isExpanded: true, itemHeight: null,
            key: const Key('settings-drive'),
            initialValue: p.drive,
            decoration: InputDecoration(labelText: context.strings.howRobotMovesLabel),
            items: [for (final d in DriveType.values) DropdownMenuItem(value: d, child: Text(widget.typeName(d)))],
            onChanged: (d) => setState(() {
              if (d == null) return;
              p = p.copyWith(drive: d, maxLinear: RobotProfile.defaultMaxLinear(d));
              _topic.text = RobotProfile.defaultCommandTopic(d);
              if (d == DriveType.none) _armEnabled = true;
            }),
          ),
          const SizedBox(height: 12),
          if (p.drive != DriveType.none)
            TextFormField(key: const Key('settings-command-topic'), controller: _topic, validator: _topicError,
              decoration: InputDecoration(labelText: context.strings.commandTopic, helperText: p.commandType, helperMaxLines: 2)),
          SwitchListTile(
            key: const Key('settings-arm'), contentPadding: EdgeInsets.zero,
            title: Text(context.strings.robotArm), subtitle: Text(context.strings.robotArmHint),
            value: _armEnabled,
            onChanged: p.drive == DriveType.none ? null : (v) => setState(() => _armEnabled = v),
          ),
          if (_armEnabled) ...[
            TextFormField(key: const Key('settings-arm-topic'), controller: _trajectory, validator: _topicError,
              decoration: InputDecoration(labelText: context.strings.armTopic, helperText: 'trajectory_msgs/JointTrajectory')),
            const SizedBox(height: 12),
            TextFormField(controller: _gripperAction,
              decoration: InputDecoration(labelText: context.strings.gripperAction, helperText: 'control_msgs/GripperCommand')),
            const SizedBox(height: 12),
            TextFormField(key: const Key('settings-joint-states-topic'), controller: _jointStates,
              validator: _optionalTopicError,
              decoration: InputDecoration(labelText: context.strings.jointStatesTopic, helperText: 'sensor_msgs/JointState',
                hintText: context.strings.autoTopic(widget.autoJointStates), floatingLabelBehavior: FloatingLabelBehavior.always)),
          ],
          if (p.drive != DriveType.none && p.drive != DriveType.aerial) ...[
            const SizedBox(height: 12),
            TextFormField(key: const Key('settings-odom-topic'), controller: _odom, validator: _optionalTopicError,
              decoration: InputDecoration(labelText: context.strings.odomTopic, helperText: context.strings.odomHelper, helperMaxLines: 2,
                hintText: context.strings.autoTopic(widget.autoOdom), floatingLabelBehavior: FloatingLabelBehavior.always)),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<CameraSource>(
            isExpanded: true, itemHeight: null,
            initialValue: p.cameraSource,
            decoration: InputDecoration(labelText: context.strings.camera),
            items: [
              DropdownMenuItem(value: CameraSource.rosImage, child: Text(context.strings.camRos)),
              DropdownMenuItem(value: CameraSource.rtsp, child: Text(context.strings.camRtsp)),
              const DropdownMenuItem(value: CameraSource.mjpeg, child: Text('MJPEG (web_video_server)')),
              DropdownMenuItem(value: CameraSource.none, child: Text(context.strings.camNone)),
            ],
            onChanged: (v) => setState(() => p = p.copyWith(cameraSource: v)),
          ),
          if (p.cameraSource == CameraSource.rosImage) ...[
            const SizedBox(height: 12),
            TextFormField(key: const Key('settings-camera-topic'), controller: _camera, validator: _topicError,
              decoration: InputDecoration(labelText: context.strings.cameraTopicLabel)),
          ],
          if (p.cameraSource == CameraSource.rtsp) ...[
            const SizedBox(height: 12),
            TextFormField(controller: _rtsp, decoration: const InputDecoration(labelText: 'RTSP URL'),
              validator: (v) {
                final uri = Uri.tryParse(v?.trim() ?? '');
                return uri == null || uri.scheme != 'rtsp' || uri.host.isEmpty ? context.strings.enterRtsp : null;
              }),
          ],
          if (p.cameraSource == CameraSource.mjpeg) ...[
            const SizedBox(height: 12),
            TextFormField(key: const Key('settings-mjpeg-url'), controller: _mjpeg,
              decoration: const InputDecoration(labelText: 'MJPEG URL (http://robot:8080/stream?topic=...)'),
              validator: (v) {
                final uri = Uri.tryParse(v?.trim() ?? '');
                return uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty
                    ? context.strings.enterHttp : null;
              }),
          ],
          const SizedBox(height: 16),
          Text(context.strings.topSpeed(p.maxLinear.toStringAsFixed(1))),
          Slider(value: p.maxLinear, min: 0.1, max: 3.0, divisions: 29,
            onChanged: (v) => setState(() => p = p.copyWith(maxLinear: v))),
          if (p.drive == DriveType.ackermann) ...[
            Text(context.strings.maxSteering((p.maxSteering * 57.2958).toStringAsFixed(0))),
            Slider(value: p.maxSteering, min: 0.1, max: 0.8, divisions: 14,
              onChanged: (v) => setState(() => p = p.copyWith(maxSteering: v))),
          ] else ...[
            Text(context.strings.maxTurnRate(p.maxAngular.toStringAsFixed(1))),
            Slider(value: p.maxAngular, min: 0.2, max: 3.0, divisions: 14,
              onChanged: (v) => setState(() => p = p.copyWith(maxAngular: v))),
          ],
        ])))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('settings-save'), onPressed: () {
          if (!_form.currentState!.validate()) return;
          final arm = _armEnabled
              ? (p.arm ?? const ArmConfig(trajectoryTopic: '')).copyWith(
                  trajectoryTopic: _trajectory.text.trim(), gripperAction: _gripperAction.text.trim())
              : null;
          Navigator.pop(context, p.copyWith(commandTopic: _topic.text.trim(), cameraTopic: _camera.text.trim(),
            rtspUrl: _rtsp.text.trim(), mjpegUrl: _mjpeg.text.trim(), arm: arm, clearArm: arm == null,
            odomTopic: _odom.text.trim(), jointStatesTopic: _jointStates.text.trim()));
        }, child: Text(context.strings.save)),
      ],
    );
  }
}
