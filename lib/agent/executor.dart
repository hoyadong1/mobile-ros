import 'dart:async';
import 'dart:math' as math;
import '../controllers/drive_controller.dart';
import '../controllers/navigation_controller.dart';
import '../controllers/odometry.dart';
import '../drive_command.dart';
import '../map_geometry.dart' show Pose2D;
import 'camera_snapshot.dart';
import '../controllers/arm_controller.dart';
import '../ros_client.dart' show ActionStatus;
import 'manifest.dart';
import 'skill.dart';

/// Carries out validated skill calls through the session controllers. It never publishes on its own:
/// motion goes through [DriveController.driveFor] (so STOP and the sticks always win) and goals
/// through [NavigationController.goTo].
///
/// Straight moves and turns are closed on odometry when it is arriving: the robot stops when it has
/// actually covered the distance or angle. Without fresh odometry they fall back to speed × time, and
/// the result says the figure is an estimate.
class SkillExecutor {
  SkillExecutor({required this.drive, required this.nav, this.odometry, this.arm, this.armPoses});

  final ArmController? arm;
  final ArmPoseBook? armPoses;

  final DriveController drive;
  final NavigationController nav;
  final Odometry? odometry;

  /// Stop this close to the target: the next 50 ms odometry sample would overshoot anyway.
  static const distanceTolerance = 0.01; // m
  static const angleTolerance = 1 * math.pi / 180; // rad
  /// Time between deciding to stop and the robot stopping: the drive loop checks every 100 ms and
  /// odometry arrives every 50 ms. Stopping this much early (at the current speed) avoids overshoot;
  /// measured in simulation as +1.3 cm on 0.5 m and +1.9° on 90° without it.
  static const reactionTime = 0.1; // s
  /// How long the base takes to come to rest after the stop command, before the result is measured.
  static const settleTime = Duration(milliseconds: 300);
  /// Speed of the slow approach that closes a shortfall, as a fraction of the move's speed.
  static const creepFactor = 0.3;

  Future<SkillResult> execute(SkillCall call, AgentManifest manifest) async {
    try {
      return switch (call.name) {
        'stop' => _stop(),
        'get_status' => SkillResult(true, _statusSentence(), status()),
        'look' => await _look(manifest),
        'arm_to_pose' => await _armToPose(call),
        'gripper' => await _gripper(call),
        'move' => await _translate(call, manifest, sideways: false),
        'strafe' => await _translate(call, manifest, sideways: true),
        'rotate' => await _rotate(call, manifest),
        'navigate_to' => await _navigate(call),
        'go_to_place' => await _goToPlace(call, manifest),
        'cancel_navigation' => _cancelNavigation(),
        _ => SkillResult.failed('Unknown skill ${call.name}.'),
      };
    } catch (e) {
      return SkillResult.failed('${call.name} failed: $e');
    }
  }

  /// What the robot is doing, for the model and for get_status.
  Map<String, Object?> status() {
    final c = drive.current, goal = nav.goal;
    return {
      'motion': drive.source?.name ?? 'stopped',
      if (!c.isStop) 'velocity': {'linear_x': c.linearX, 'linear_y': c.linearY, 'angular_z': c.angularZ},
      'navigation': nav.status.name,
      if (goal != null) 'goal': {'x': _round(goal.x), 'y': _round(goal.y)},
      if (nav.isActive && nav.distanceRemaining != null) 'distance_remaining_m': _round(nav.distanceRemaining!),
    };
  }

  SkillResult _stop() {
    drive.stop();
    arm?.stop();
    nav.cancel();
    return const SkillResult(true, 'Stopped.');
  }

  SkillResult? _blockedByNavigation() => nav.isActive
      ? const SkillResult.failed('Navigation is running. Cancel it before driving directly.')
      : null;

  Future<SkillResult> _translate(SkillCall call, AgentManifest manifest, {required bool sideways}) async {
    final blocked = _blockedByNavigation();
    if (blocked != null) return blocked;
    final p = manifest.profile!;
    final distance = call.args['distance_m'] as double;
    if (distance == 0) return const SkillResult(true, 'Nothing to do: distance is 0.');
    final speed = p.maxLinear * manifest.limits.speedScales[call.args['speed']]!;
    final v = distance.sign * speed;
    final command = sideways ? DriveCommand(linearY: v) : DriveCommand(linearX: v);
    final what = sideways ? (distance > 0 ? 'left' : 'right') : (distance > 0 ? 'forward' : 'backward');
    final target = distance.abs();
    final seconds = target / speed;

    final lead = distanceTolerance + speed * reactionTime;
    final closed = await _closedLoop(command, seconds, (progress) => progress.distance >= target - lead,
        finish: (
          remaining: (progress) => target - progress.distance,
          tolerance: distanceTolerance,
          speed: speed * creepFactor,
          command: sideways ? DriveCommand(linearY: v * creepFactor) : DriveCommand(linearX: v * creepFactor),
        ));
    if (closed == null) {
      final finished = await drive.driveFor(command, _duration(seconds));
      return finished
          ? SkillResult(true, 'Moved about ${_round(target)} m $what (estimated from time; no odometry).')
          : _interrupted;
    }
    final (end, progress, stale) = closed;
    final moved = _round(progress.distance);
    if (stale) return SkillResult.failed('Stopped after $moved m: odometry stopped arriving.', {'moved_m': moved});
    return switch (end) {
      DriveEnd.reached => SkillResult(true, 'Moved $moved m $what.', {'moved_m': moved}),
      DriveEnd.timeUp => SkillResult.failed('Stopped after $moved m of ${_round(target)} m: the robot did not get '
          'there in time (blocked or slipping?).', {'moved_m': moved}),
      DriveEnd.interrupted => SkillResult.failed('${_interrupted.message} Moved $moved m.', {'moved_m': moved}),
    };
  }

  static const _interrupted =
      SkillResult.failed('Stopped before finishing: someone took control or a stop was requested.');

  /// Runs [command] until [reached] says so from odometry, or until 1.5 x the expected time plus a
  /// second. Returns null when there is no fresh odometry (the caller then falls back to timing).
  /// `stale` is true when odometry stopped arriving mid-motion, which also stops the robot.
  ///
  /// The stop is commanded early by the reaction time, which suits a base that coasts (TurtleBot3). One
  /// that halts at once (a planar-move or stiff industrial base) then stops short, so with [finish] a
  /// shortfall of more than twice the tolerance is closed by one slow approach.
  Future<(DriveEnd, MotionProgress, bool)?> _closedLoop(
      DriveCommand command, double expectedSeconds, bool Function(MotionProgress) reached,
      {({double Function(MotionProgress) remaining, double tolerance, double speed, DriveCommand command})? finish}) async {
    final odom = odometry;
    if (odom == null || !await odom.waitFresh()) return null;
    final start = odom.pose!;
    final progress = MotionProgress(start);
    var stale = false;
    var end = await drive.driveUntil(command, _duration(expectedSeconds * 1.5 + 1), () {
      if (!odom.isFresh()) return stale = true;
      progress.update(odom.pose!);
      return reached(progress);
    });
    Future<void> settle() async {
      // Report where the robot came to rest, not where it was when told to stop.
      await Future<void>.delayed(settleTime);
      if (odom.isFresh()) progress.update(odom.pose!);
    }
    if (!stale) await settle();
    if (!stale && end == DriveEnd.reached && finish != null) {
      final left = finish.remaining(progress);
      if (left > finish.tolerance * 2) {
        final lead = finish.tolerance + finish.speed * reactionTime;
        final again = await drive.driveUntil(finish.command, _duration(left / finish.speed * 1.5 + 1), () {
          if (!odom.isFresh()) return stale = true;
          progress.update(odom.pose!);
          return finish.remaining(progress) <= lead;
        });
        if (!stale) await settle();
        // Too slow to move this base at all: keep what the first pass reached rather than fail.
        if (again == DriveEnd.interrupted) end = again;
      }
    }
    return (end, progress, stale);
  }

  Future<SkillResult> _rotate(SkillCall call, AgentManifest manifest) async {
    final blocked = _blockedByNavigation();
    if (blocked != null) return blocked;
    final p = manifest.profile!;
    final degrees = call.args['angle_deg'] as double;
    if (degrees == 0) return const SkillResult(true, 'Nothing to do: angle is 0.');
    final rate = p.maxAngular * manifest.limits.speedScales[call.args['speed']]!;
    final radians = degrees.abs() * math.pi / 180;
    final command = DriveCommand(angularZ: degrees.sign * rate);
    final side = degrees > 0 ? 'left' : 'right';

    final closed = await _closedLoop(command, radians / rate,
        (progress) => progress.turned.abs() >= radians - (angleTolerance + rate * reactionTime),
        finish: (
          remaining: (progress) => radians - progress.turned.abs(),
          tolerance: angleTolerance,
          speed: rate * creepFactor,
          command: DriveCommand(angularZ: degrees.sign * rate * creepFactor),
        ));
    if (closed == null) {
      final finished = await drive.driveFor(command, _duration(radians / rate));
      return finished
          ? SkillResult(true, 'Turned about ${degrees.abs().round()}° $side (estimated from time; no odometry).')
          : _interrupted;
    }
    final (end, progress, stale) = closed;
    final turned = (progress.turned.abs() * 180 / math.pi).round();
    if (stale) return SkillResult.failed('Stopped after $turned°: odometry stopped arriving.', {'turned_deg': turned});
    return switch (end) {
      DriveEnd.reached => SkillResult(true, 'Turned $turned° $side.', {'turned_deg': turned}),
      DriveEnd.timeUp => SkillResult.failed('Stopped after $turned° of ${degrees.abs().round()}°: the robot did not '
          'turn far enough in time.', {'turned_deg': turned}),
      DriveEnd.interrupted => SkillResult.failed('${_interrupted.message} Turned $turned°.', {'turned_deg': turned}),
    };
  }

  Future<SkillResult> _navigate(SkillCall call) async {
    final x = call.args['x'] as double, y = call.args['y'] as double;
    final yaw = (call.args['yaw_deg'] as double? ?? 0) * math.pi / 180;
    final outcome = await nav.goTo(Pose2D(x, y, yaw));
    final where = '(${_round(x)}, ${_round(y)})';
    return switch (outcome) {
      NavStatus.succeeded => SkillResult(true, 'Arrived at $where.'),
      NavStatus.canceled => SkillResult.failed('Navigation to $where was canceled.'),
      _ => SkillResult.failed('Could not reach $where${nav.detail == null ? '.' : ': ${nav.detail}'}'),
    };
  }

  Future<SkillResult> _goToPlace(SkillCall call, AgentManifest manifest) async {
    final name = call.args['name'] as String;
    final place = manifest.place(name);
    if (place == null) return SkillResult.failed('There is no saved place called "$name".');
    final outcome = await nav.goTo(place.pose, frame: place.frame);
    return switch (outcome) {
      NavStatus.succeeded => SkillResult(true, 'Arrived at ${place.name}.'),
      NavStatus.canceled => SkillResult.failed('Going to ${place.name} was canceled.'),
      _ => SkillResult.failed('Could not reach ${place.name}${nav.detail == null ? '.' : ': ${nav.detail}'}'),
    };
  }

  Future<SkillResult> _armToPose(SkillCall call) async {
    final a = arm;
    if (a == null || !a.configured) return const SkillResult.failed('This robot has no arm set up.');
    final name = call.args['name'] as String;
    final pose = armPoses?.find(name, joints: a.joints);
    if (pose == null) return SkillResult.failed('There is no saved arm posture called "$name".');
    final end = await a.moveTo(pose.joints);
    final off = (a.errorTo(pose.joints) * 180 / math.pi).toStringAsFixed(1);
    return switch (end) {
      ArmEnd.reached => SkillResult(true, 'The arm is at "${pose.name}".', {'error_deg': off}),
      ArmEnd.timeUp => SkillResult.failed('The arm did not reach "${pose.name}" in time (still $off° off). '
          'It may be blocked.', {'error_deg': off}),
      ArmEnd.interrupted => SkillResult.failed('Stopped before the arm reached "${pose.name}".'),
      ArmEnd.failed => const SkillResult.failed('Could not move the arm: no joint states from the robot.'),
    };
  }

  Future<SkillResult> _gripper(SkillCall call) async {
    final a = arm;
    if (a == null || !a.hasGripper) return const SkillResult.failed('This robot has no gripper set up.');
    final open = call.args['action'] == 'open';
    final status = await a.gripper(open);
    return status == ActionStatus.succeeded
        ? SkillResult(true, open ? 'Opened the gripper.' : 'Closed the gripper.')
        : SkillResult.failed('The gripper did not ${open ? 'open' : 'close'} (${status.name}).');
  }

  Future<SkillResult> _look(AgentManifest manifest) async {
    final topic = manifest.profile?.cameraTopic ?? '';
    if (topic.isEmpty) return const SkillResult.failed('The robot has no camera set up.');
    try {
      final shot = await takeSnapshot(drive.ros, topic);
      return SkillResult(true, 'Took a picture with the camera ($topic). It is attached.',
          {'camera': topic, 'bytes': shot.bytes.length}, shot.bytes, shot.mimeType);
    } on TimeoutException {
      return SkillResult.failed('No picture arrived from $topic within 5 seconds.');
    } on FormatException catch (e) {
      return SkillResult.failed('Could not use the picture from $topic: ${e.message}');
    }
  }

  SkillResult _cancelNavigation() {
    if (!nav.isActive) return const SkillResult(true, 'No navigation goal was running.');
    nav.cancel();
    return const SkillResult(true, 'Navigation canceled.');
  }

  String _statusSentence() {
    final motion = drive.source == null ? 'not moving' : 'moving (${drive.source!.name})';
    final navText = switch (nav.status) {
      NavStatus.active => 'navigating${nav.distanceRemaining == null ? '' : ', ${_round(nav.distanceRemaining!)} m left'}',
      NavStatus.idle => 'no navigation goal',
      final s => 'last navigation ${s.name}',
    };
    return 'The robot is $motion; $navText.';
  }

  static Duration _duration(double seconds) => Duration(milliseconds: (seconds * 1000).round());
  static double _round(double v) => (v * 100).round() / 100;
}
