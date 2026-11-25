import 'dart:async';
import 'package:flutter/foundation.dart';
import '../drive_command.dart';
import '../navigation_goal.dart' show RosVersion;
import '../robot_profile.dart';
import '../ros_client.dart';
import 'automation_gate.dart';

/// Who is moving the base right now.
enum DriveSource { manual, agent }

/// How an agent motion ended.
enum DriveEnd {
  /// The condition given to [DriveController.driveUntil] was met.
  reached,
  /// The time limit ran out first (for [DriveController.driveFor] that is the normal end).
  timeUp,
  /// A person took over, [DriveController.stop] was called, a newer motion replaced it, or the base
  /// cannot be driven.
  interrupted,
}

/// The single owner of the base's velocity command. Several sources may want to drive; this decides:
///
///   1. [stop] wins over everything and ends any agent motion.
///   2. A person on the sticks ([manualInput] non-zero) overrides the agent and ends its motion.
///   3. The agent drives only through [driveFor], which always has an end time, so a lost agent can
///      never leave the robot moving.
///
/// Every [period] the chosen command is published while something is moving (so the robot's own
/// velocity timeout never fires mid-drive), then one zero command when motion ends.
///
/// Drones are not arbitrated here yet: their OFFBOARD setpoint stream stays with the control screen,
/// which publishes through [sendNow].
class DriveController extends ChangeNotifier {
  DriveController(this.ros, {this.period = const Duration(milliseconds: 100)});

  final RosClient ros;
  final Duration period;
  final automation = AutomationGate();

  /// The person's current stick command (already scaled for the profile and speed preset).
  DriveCommand Function() manualInput = () => DriveCommand.stop;

  RobotProfile? _profile;
  RosVersion _version = RosVersion.ros2;
  RosPublisher? _publisher;
  Timer? _timer;

  DriveCommand _agentCommand = DriveCommand.stop;
  DateTime? _agentUntil;
  bool Function()? _agentReached;
  Completer<DriveEnd>? _agentDone;

  DriveCommand _current = DriveCommand.stop;
  DriveSource? _source;
  /// Motion commands on the base's topic that this app did not send: another phone, a joystick, Nav2.
  StreamSubscription<Map<String, dynamic>>? _watch;
  DateTime? _otherAt;
  bool _otherShown = false;
  bool _sentMotion = false;
  String? _lastError;
  bool _disposed = false;

  RobotProfile? get profile => _profile;
  /// The command most recently chosen (zero when nothing drives).
  DriveCommand get current => _current;
  /// Who produced [current], or null when stopped.
  DriveSource? get source => _source;
  bool get agentDriving => _agentDone != null;

  /// When a non-zero command was last published (null if never). If the link drops shortly after, the
  /// robot may still be executing it.
  DateTime? get lastMotionAt => _lastMotionAt;
  DateTime? _lastMotionAt;
  String? get lastError => _lastError;

  /// Whether something else sent the base a motion command in the last 2 s (seen while this app was not
  /// driving, so it is not our own command coming back). Two drivers on one base fight each other.
  bool get otherDriving => _otherAt != null && DateTime.now().difference(_otherAt!) < const Duration(seconds: 2);

  /// Takes a message seen on the command topic. Public for tests.
  void observeCommand(Map<String, dynamic> msg, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final ours = _lastMotionAt != null && at.difference(_lastMotionAt!) < const Duration(milliseconds: 700);
    if (ours || !_hasMotion(msg)) return;
    _otherAt = at;
    if (!_otherShown) {
      _otherShown = true;
      notifyListeners();
    }
  }

  static bool _hasMotion(Object? v) => switch (v) {
    num n => n.abs() > 1e-3,
    Map m => m.entries.any((e) => e.key != 'header' && _hasMotion(e.value)),
    List l => l.any(_hasMotion),
    _ => false,
  };

  bool get _arbitrated => _profile != null && _profile!.hasBase && _profile!.drive != DriveType.aerial;

  bool _stamped = false;
  /// Whether commands go out as `geometry_msgs/TwistStamped` (the robot's command topic is of that type).
  bool get stamped => _stamped;

  /// Uses [profile]'s command topic and message type. Stops the base first. [commandTopicType] is the type
  /// the robot lists for that topic, when known: a `TwistStamped` topic gets stamped commands (a plain
  /// Twist there is refused by rosbridge and moves nothing).
  void configure(RobotProfile? profile, RosVersion version, {String? commandTopicType}) {
    stop();
    _profile = profile;
    _version = version;
    final type = profile?.commandTypeOn(commandTopicType);
    _stamped = isTwistStamped(type);
    final want = profile != null && profile.hasBase ? (profile.commandTopic, type!) : null;
    try {
      if (want == null) {
        _publisher?.close();
        _publisher = null;
      } else if (_publisher == null || _publisher!.isClosed || _publisher!.topic != rosName(want.$1) ||
          _publisher!.type != want.$2) {
        final next = ros.advertise(want.$1, want.$2);
        _publisher?.close();
        _publisher = next;
      }
      _lastError = null;
    } catch (e) {
      _lastError = '$e';
    }
    _timer?.cancel();
    _timer = _arbitrated ? Timer.periodic(period, (_) => tick()) : null;
    _watch?.cancel();
    _watch = null;
    _otherAt = null;
    _otherShown = false;
    if (want != null && _arbitrated) {
      try {
        _watch = ros.subscribe(want.$1, type: want.$2, throttleRate: 200).listen(observeCommand, onError: (_) {});
      } catch (_) {}
    }
    notifyListeners();
  }

  /// Chooses and publishes the command now. Runs every [period]; call it as well when the sticks move
  /// so the robot reacts without waiting for the next tick.
  void tick() {
    if (_otherShown && !otherDriving) {
      _otherShown = false;
      notifyListeners();
    }
    if (_disposed || !_arbitrated || _publisher == null) return;
    final manual = manualInput();
    final now = DateTime.now();
    if (agentDriving) {
      final reached = _agentReached;
      if (reached != null && reached()) {
        _endAgent(DriveEnd.reached);
      } else if (_agentUntil != null && !now.isBefore(_agentUntil!)) {
        _endAgent(DriveEnd.timeUp);
      }
    }

    DriveCommand next;
    DriveSource? source;
    if (!manual.isStop) {
      if (agentDriving) _endAgent(DriveEnd.interrupted); // the person takes over
      next = manual;
      source = DriveSource.manual;
    } else if (agentDriving) {
      next = _agentCommand;
      source = DriveSource.agent;
    } else {
      next = DriveCommand.stop;
    }

    if (next.isStop && !_sentMotion) {
      _setCurrent(next, null);
      return;
    }
    _publish(next);
    _sentMotion = !next.isStop;
    _setCurrent(next, next.isStop ? null : source);
  }

  /// Agent motion: holds [command] for [duration], then stops. Completes with true if it ran the
  /// full time, false if a person took over, [stop] was called, or the base cannot be driven.
  /// A new call replaces a running one (which completes with false).
  Future<bool> driveFor(DriveCommand command, Duration duration) async =>
      await driveUntil(command, duration, null) == DriveEnd.timeUp;

  /// Agent motion: holds [command] until [reached] returns true (checked every [period] and on every
  /// [tick]) or [limit] passes, then stops. The limit always applies, so a condition that never comes
  /// true (no odometry, a stuck wheel) still ends the motion.
  Future<DriveEnd> driveUntil(DriveCommand command, Duration limit, bool Function()? reached) {
    if (_disposed || !_arbitrated || _publisher == null) return Future.value(DriveEnd.interrupted);
    if (!manualInput().isStop) return Future.value(DriveEnd.interrupted); // someone is driving by hand
    if (agentDriving) _endAgent(DriveEnd.interrupted);
    final done = _agentDone = Completer<DriveEnd>();
    _agentCommand = command;
    _agentUntil = DateTime.now().add(limit);
    _agentReached = reached;
    tick();
    return done.future;
  }

  /// Zero velocity now, from any source. Ends agent motion.
  void stop() {
    if (agentDriving) _endAgent(DriveEnd.interrupted);
    if (_profile?.hasBase == true) _publish(DriveCommand.stop);
    _sentMotion = false;
    _setCurrent(DriveCommand.stop, null);
  }

  /// Publishes [command] directly, outside arbitration (the drone setpoint stream).
  void sendNow(DriveCommand command) => _publish(command);

  void _endAgent(DriveEnd end) {
    final done = _agentDone;
    _agentDone = null;
    _agentUntil = null;
    _agentReached = null;
    _agentCommand = DriveCommand.stop;
    if (done != null && !done.isCompleted) done.complete(end);
  }

  void _publish(DriveCommand command) {
    final p = _profile, publisher = _publisher;
    if (p == null || publisher == null || ros.isClosed) return;
    try {
      publisher.publish(commandMessage(p, command, _version, stamped: _stamped));
      if (!command.isStop) _lastMotionAt = DateTime.now();
    } catch (e) {
      _lastError = '$e';
    }
  }

  void _setCurrent(DriveCommand command, DriveSource? source) {
    if (_same(command, _current) && source == _source) return;
    _current = command;
    _source = source;
    notifyListeners();
  }

  static bool _same(DriveCommand a, DriveCommand b) => a.linearX == b.linearX && a.linearY == b.linearY &&
      a.linearZ == b.linearZ && a.angularZ == b.angularZ && a.steering == b.steering;

  /// Stops the base and withdraws the command topic.
  @override
  void dispose() {
    _watch?.cancel();
    if (_disposed) return;
    automation.close();
    _timer?.cancel();
    _endAgent(DriveEnd.interrupted);
    _publish(DriveCommand.stop);
    _publisher?.close();
    _publisher = null;
    _disposed = true;
    super.dispose();
  }
}
