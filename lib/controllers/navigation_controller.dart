import 'dart:async';

import '../nav_activity.dart';
import 'package:flutter/foundation.dart';
import '../map_geometry.dart' show Pose2D;
import '../navigation_goal.dart';
import '../ros_client.dart';

/// How goals reach the navigation stack, best first.
enum NavMode {
  /// Nav2 NavigateToPose action: progress, result and cancel.
  action,
  /// ROS 2 /goal_pose topic (no feedback; cancel through the action's cancel service).
  goalPose,
  /// ROS 1 move_base goal topic (cancel on /move_base/cancel).
  moveBase,
}

/// Where the current (or last) goal stands.
enum NavStatus { idle, active, succeeded, canceled, failed }

/// Sends navigation goals and follows them to the end, independent of any screen. The map page drives
/// it from taps; the AI agent will drive it from skills. Listeners are notified on every change.
///
/// Without an action server there is no feedback, so arrival is judged from the robot position the
/// owner passes to [updateRobotPose].
class NavigationController extends ChangeNotifier {
  NavigationController(this.ros);

  final RosClient ros;

  /// Distance at which a goal sent without feedback counts as reached.
  static const arrivalRadius = 0.3;
  static const abortedDetail = 'Nav2 stopped before completing this goal. Check the robot log for the cause.';

  RosVersion _version = RosVersion.ros2;
  NavMode _mode = NavMode.goalPose;
  String _navigateAction = navigateToPoseAction;
  String _moveBaseAction = '/move_base';
  GoalChannel _goalChannel = goalChannel(RosVersion.ros2);
  RosPublisher? _goalPublisher, _cancelPublisher;

  NavStatus _status = NavStatus.idle;
  Pose2D? _goal;
  double? _distanceRemaining, _etaSeconds, _startDistance;
  int _recoveries = 0;
  String? _detail;
  ActionHandle? _handle;
  StreamSubscription<Map<String, dynamic>>? _feedback;
  StreamSubscription<Map<String, dynamic>>? _treeLog;
  /// What Nav2 is doing during a goal (planning, following, a recovery), from its behavior tree log.
  final activityTracker = NavActivityTracker();
  Completer<NavStatus>? _finished;
  bool _disposed = false;
  bool _configured = false;

  NavMode get mode => _mode;
  /// Whether [configure] has run; goals can be sent only after it.
  bool get configured => _configured;
  /// Whether a navigation stack was actually found (an action server or a goal topic), as opposed to
  /// [configure] falling back to the conventional `/goal_pose` nobody may be listening on. The AI
  /// assistant offers navigation only when this is true.
  bool get available => _configured && _found;
  bool _found = false;
  RosVersion get version => _version;
  String get navigateAction => _navigateAction;
  GoalChannel get goalChannelInUse => _goalChannel;
  NavStatus get status => _status;
  /// Goals sent so far: tells one trip from the next even when they follow without a pause.
  int goalCount = 0;
  bool get isActive => _status == NavStatus.active;
  Pose2D? get goal => _goal;
  /// Metres left: from Nav2 feedback, or the straight line to the goal without it.
  double? get distanceRemaining => _distanceRemaining;
  double? get etaSeconds => _etaSeconds;
  /// The largest distance seen for this goal, for a progress bar.
  double? get startDistance => _startDistance;
  int get recoveries => _recoveries;
  /// What Nav2 is doing now, when its behavior tree log is available (action mode, Nav2).
  NavActivity? get activity => isActive ? activityTracker.current : null;
  /// Extra explanation of the outcome, if any.
  String? get detail => _detail;

  /// What goals go to, for display.
  String get label => switch (_mode) {
    NavMode.action => _navigateAction == navigateToPoseAction ? 'Nav2 · navigate_to_pose' : 'Nav2 · $_navigateAction',
    NavMode.goalPose => 'Nav2 · ${_goalChannel.topic}',
    NavMode.moveBase => _moveBaseAction == '/move_base' ? 'ROS 1 · move_base' : 'ROS 1 · $_moveBaseAction',
  };

  /// Points the controller at the robot's navigation stack: a NavigateToPose action server
  /// ([navigateAction]) if there is one, else the ROS 2 [goalTopic] or ROS 1 move_base. Advertises the
  /// topics that mode publishes on. Call it again when the topic choice changes.
  ///
  /// [found] says whether discovery saw a navigation stack; by default, whether any of the names is given.
  void configure({required RosVersion version, String? navigateAction, String? goalTopic, String? moveBaseAction,
      bool? found}) {
    _found = found ?? (navigateAction != null || goalTopic != null || moveBaseAction != null);
    if (moveBaseAction != null) _moveBaseAction = moveBaseAction;
    if (navigateAction != null) _navigateAction = navigateAction; // also where goalPose cancels
    final mode = version == RosVersion.ros1 ? NavMode.moveBase
        : navigateAction != null ? NavMode.action : NavMode.goalPose;
    final topic = version == RosVersion.ros1 ? '$_moveBaseAction/goal' : goalTopic ?? '/goal_pose';
    _goalChannel = GoalChannel(topic,
        version == RosVersion.ros1 ? 'move_base_msgs/MoveBaseActionGoal' : 'geometry_msgs/msg/PoseStamped',
        version == RosVersion.ros1 ? 'ROS 1 · $_moveBaseAction' : 'Nav2 · $topic');
    _version = version;
    _mode = mode;
    _configured = true;
    _goalPublisher = _replace(_goalPublisher,
        mode == NavMode.action ? null : (_goalChannel.topic, _goalChannel.type));
    _cancelPublisher = _replace(_cancelPublisher,
        mode == NavMode.moveBase ? ('$_moveBaseAction/cancel', 'actionlib_msgs/GoalID') : null);
    notifyListeners();
  }

  RosPublisher? _replace(RosPublisher? current, (String, String)? want) {
    if (want == null) {
      current?.close();
      return null;
    }
    final (topic, type) = want;
    if (current != null && !current.isClosed && current.topic == rosName(topic) && current.type == type) {
      return current;
    }
    final next = ros.advertise(topic, type);
    current?.close(); // after advertising, so a shared advertisement is not withdrawn in between
    return next;
  }

  /// Sends a goal to [target] in [frame] and returns its final status. [from] (the robot's pose, if
  /// known) seeds the distance shown before any feedback arrives. A goal that is still running is
  /// superseded: the navigation stack replaces it, and its future completes as canceled.
  ///
  /// Throws if the goal could not be published (topic modes); in action mode a goal that cannot be
  /// sent ends as [NavStatus.failed] instead.
  Future<NavStatus> goTo(Pose2D target, {String frame = 'map', Pose2D? from}) {
    if (_disposed) throw StateError('NavigationController was disposed');
    ActionHandle? handle;
    if (_mode == NavMode.action) {
      handle = ros.sendActionGoal(_navigateAction, navigateToPoseType,
          navigateToPoseArgs(frame, target.x, target.y, target.yaw));
    } else {
      final publisher = _goalPublisher;
      if (publisher == null) throw StateError('Navigation is not configured');
      publisher.publish(goalMessage(_version, frame, target.x, target.y,
          'mobile_ros_${DateTime.now().microsecondsSinceEpoch}', yaw: target.yaw));
    }
    _detach(NavStatus.canceled);
    final finished = _finished = Completer<NavStatus>();
    _status = NavStatus.active;
    _goal = target;
    goalCount++;
    _detail = null;
    _recoveries = 0;
    _etaSeconds = null;
    _distanceRemaining = from?.distanceTo(target);
    _startDistance = _distanceRemaining;
    activityTracker.reset();
    if (handle != null) {
      _follow(handle, target, frame, retries: 1);
      _watchTree();
    }
    notifyListeners();
    return finished.future;
  }

  /// rosbridge's own failure while sending a goal ("Object of type 'NoneType' is not an instance of
  /// 'capsule'"): seen now and then when several robots' Nav2 got goals over one rosbridge, the goal
  /// failing on the phone while the robot sometimes set off anyway. Sending it again settles it (a goal
  /// that did start is simply replaced by the same one).
  static bool _rosbridgeGlitch(String? error) => error != null && error.contains("not an instance of 'capsule'");

  void _follow(ActionHandle handle, Pose2D target, String frame, {required int retries}) {
    _handle = handle;
    _feedback?.cancel();
    _feedback = handle.feedback.listen(_onFeedback);
    handle.result.then((result) async {
      if (_handle != handle) return; // superseded, canceled or disposed
      if (result.status == ActionStatus.failed && retries > 0 && _rosbridgeGlitch(result.error)) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        if (_handle != handle || _disposed) return;
        _follow(ros.sendActionGoal(_navigateAction, navigateToPoseType,
            navigateToPoseArgs(frame, target.x, target.y, target.yaw)), target, frame, retries: retries - 1);
        return;
      }
      switch (result.status) {
        case ActionStatus.succeeded:
          _complete(NavStatus.succeeded);
        case ActionStatus.canceled:
          _complete(NavStatus.canceled);
        case ActionStatus.aborted:
          _complete(NavStatus.failed, detail: _failureDetail(result));
        case ActionStatus.failed:
          _complete(NavStatus.failed, detail: result.error ?? abortedDetail);
        case ActionStatus.unknown:
          _complete(NavStatus.failed);
      }
    });
  }

  String _failureDetail(ActionResult result) {
    final values = result.values;
    if (values is Map) {
      final message = values['error_msg'], code = values['error_code'];
      if (message is String && message.trim().isNotEmpty) return 'Nav2: ${message.trim()}';
      if (code is num && code != 0) return 'Nav2 stopped (error $code). Check the robot log for the cause.';
    }
    // Humble returns an Empty result. An abort alone does not identify a path-planning failure.
    return abortedDetail;
  }

  /// Stops the running goal. The status becomes canceled right away.
  void cancel() {
    if (!isActive) return;
    try {
      switch (_mode) {
        case NavMode.action:
          _handle?.cancel();
        case NavMode.goalPose:
          // Goals sent on /goal_pose run as NavigateToPose actions inside Nav2: cancel them all.
          ros.connection.send({'op': 'call_service', 'id': ros.nextId('cancel'),
            'service': '$_navigateAction/_action/cancel_goal', 'args': {}});
        case NavMode.moveBase:
          _cancelPublisher?.publish({'stamp': {'secs': 0, 'nsecs': 0}, 'id': ''});
      }
    } catch (_) {
      // The connection is gone; the robot's own stack keeps or drops the goal.
    }
    _complete(NavStatus.canceled);
  }

  /// Without action feedback, the robot's position decides arrival and the distance left.
  void updateRobotPose(Pose2D? robot) {
    final target = _goal;
    if (!isActive || _mode == NavMode.action || target == null || robot == null) return;
    final d = robot.distanceTo(target);
    if (d < arrivalRadius) {
      _complete(NavStatus.succeeded, detail: 'Within ${arrivalRadius.toStringAsFixed(1)} m of the goal.');
    } else if (_distanceRemaining != d) {
      _distanceRemaining = d;
      notifyListeners();
    }
  }

  /// Forgets a finished goal. Does nothing while one is running.
  void reset() {
    if (isActive || _status == NavStatus.idle) return;
    _status = NavStatus.idle;
    _goal = null;
    _detail = null;
    notifyListeners();
  }

  /// Follows bt_navigator's log while the goal runs. A robot without it (or a bridge that cannot read the
  /// type) simply shows no activity.
  void _watchTree() {
    if (_treeLog != null) return;
    try {
      _treeLog = ros.subscribe(behaviorTreeLogTopic(_navigateAction), type: 'nav2_msgs/msg/BehaviorTreeLog')
          .listen((msg) {
        if (isActive && activityTracker.onLog(msg)) notifyListeners();
      }, onError: (_) {});
    } catch (_) {}
  }

  void _onFeedback(Map<String, dynamic> values) {
    if (!isActive) return;
    _distanceRemaining = (values['distance_remaining'] as num?)?.toDouble() ?? _distanceRemaining;
    // Nav2 measures along the path, which can be longer than the straight line measured at the start.
    final d = _distanceRemaining, start = _startDistance;
    if (d != null && (start == null || d > start)) _startDistance = d;
    final eta = values['estimated_time_remaining'];
    if (eta is Map) _etaSeconds = (eta['sec'] as num? ?? 0) + (eta['nanosec'] as num? ?? 0) / 1e9;
    _recoveries = (values['number_of_recoveries'] as num?)?.toInt() ?? _recoveries;
    notifyListeners();
  }

  void _complete(NavStatus status, {String? detail}) {
    if (!isActive) return;
    _detach(status);
    _status = status;
    _detail = detail;
    notifyListeners();
  }

  /// Stops following the current goal and completes its future with [status].
  void _detach(NavStatus status) {
    _feedback?.cancel();
    _feedback = null;
    _treeLog?.cancel();
    _treeLog = null;
    _handle = null;
    final finished = _finished;
    _finished = null;
    if (finished != null && !finished.isCompleted) finished.complete(status);
  }

  /// Withdraws the advertisements. A running goal keeps running on the robot; its future completes
  /// as failed since nobody follows it any more.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detach(NavStatus.failed);
    _goalPublisher?.close();
    _cancelPublisher?.close();
    _goalPublisher = _cancelPublisher = null;
    super.dispose();
  }
}
