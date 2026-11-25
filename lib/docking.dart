import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ros_client.dart';

/// Nav2's docking server (opennav_docking): the robot drives to its charger by name, and backs off it again.
/// The dock's name is the id in the robot's own dock database (its `docks` parameter); the app asks the
/// person for it once and remembers it.
const dockRobotAction = '/dock_robot';
const undockRobotAction = '/undock_robot';
const dockRobotType = 'nav2_msgs/action/DockRobot';
const undockRobotType = 'nav2_msgs/action/UndockRobot';

enum DockStatus { idle, docking, undocking, docked, undocked, canceled, failed }

/// The goal for docking at the dock named [dockId] in the robot's database: navigate to its staging pose,
/// find the dock and drive on.
Map<String, dynamic> dockRobotArgs(String dockId) => {
  'use_dock_id': true,
  'dock_id': dockId,
  'dock_pose': {'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': ''}, 'pose': {
    'position': {'x': 0.0, 'y': 0.0, 'z': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
  'dock_type': '',
  'max_staging_time': 1000.0,
  'navigate_to_staging_pose': true,
};

/// Docking error codes of Nav2 (DockRobot / UndockRobot results) as a sentence, or null for none.
String? dockErrorText(int? code) => switch (code) {
  null || 0 => null,
  901 => 'The dock is not in the robot\'s dock database.',
  902 => 'The dock is not valid.',
  903 => 'The robot could not get to the dock\'s staging pose.',
  904 => 'The robot could not see the dock.',
  905 => 'The robot could not drive onto the dock.',
  906 => 'The robot reached the dock but is not charging.',
  _ => 'Docking stopped (error $code).',
};

/// What the robot is doing while docking (DockRobot feedback state).
enum DockStage { starting, navigating, detecting, controlling, waitingForCharge, retrying }

DockStage dockStageOf(Object? state) => switch (state) {
  1 => DockStage.navigating,
  2 => DockStage.detecting,
  3 => DockStage.controlling,
  4 => DockStage.waitingForCharge,
  5 => DockStage.retrying,
  _ => DockStage.starting,
};

class DockController extends ChangeNotifier {
  DockController(this.ros);

  final RosClient ros;

  String? _dock, _undock;
  DockStatus _status = DockStatus.idle;
  DockStage _stage = DockStage.starting;
  int _retries = 0;
  int? _errorCode;
  String? _detail, _dockId;
  ActionHandle? _handle;
  StreamSubscription<Map<String, dynamic>>? _feedback;
  Completer<DockStatus>? _finished;
  bool _disposed = false;

  bool get canDock => _dock != null;
  bool get canUndock => _undock != null;
  /// Whether the robot has a docking server at all.
  bool get available => canDock || canUndock;
  DockStatus get status => _status;
  bool get isBusy => _status == DockStatus.docking || _status == DockStatus.undocking;
  DockStage get stage => _stage;
  int get retries => _retries;
  String? get detail => _detail;
  /// Nav2's error code of a failed dock or undock (see [dockErrorText]), when it gave one.
  int? get errorCode => _errorCode;
  String? get dockId => _dockId;

  /// The robot's dock and undock actions among [actionNames] (its own namespace first).
  void configure(List<String> actionNames, {String namespace = ''}) {
    String? find(String name) {
      final mine = actionNames.where((a) => a == name || a.endsWith(name)).toList();
      final ns = namespace == '/' ? '' : namespace;
      if (mine.isEmpty) return null;
      if (ns.isNotEmpty) return mine.where((a) => a == '$ns$name').firstOrNull;
      return mine.where((a) => a == name).firstOrNull ?? (mine.length == 1 ? mine.first : null);
    }

    final dock = find(dockRobotAction), undock = find(undockRobotAction);
    if (dock == _dock && undock == _undock) return;
    _dock = dock;
    _undock = undock;
    notifyListeners();
  }

  /// Docks at [dockId]. Completes with how it ended.
  Future<DockStatus> dockAt(String dockId) {
    final action = _dock;
    if (_disposed) throw StateError('DockController was disposed');
    if (action == null) throw StateError('This robot has no docking server.');
    if (dockId.trim().isEmpty) throw ArgumentError('A dock name is needed.');
    return _run(DockStatus.docking, action, dockRobotType, dockRobotArgs(dockId.trim()), dockId: dockId.trim());
  }

  /// Backs off the charger.
  Future<DockStatus> undock() {
    final action = _undock;
    if (_disposed) throw StateError('DockController was disposed');
    if (action == null) throw StateError('This robot has no docking server.');
    return _run(DockStatus.undocking, action, undockRobotType, {'dock_type': '', 'max_undocking_time': 30.0});
  }

  Future<DockStatus> _run(DockStatus busy, String action, String type, Map<String, dynamic> args, {String? dockId}) {
    _detach(DockStatus.canceled);
    final finished = _finished = Completer<DockStatus>();
    _status = busy;
    _stage = DockStage.starting;
    _retries = 0;
    _detail = null;
    _errorCode = null;
    _dockId = dockId ?? _dockId;
    final handle = _handle = ros.sendActionGoal(action, type, args);
    _feedback = handle.feedback.listen((values) {
      if (_handle != handle) return;
      _stage = dockStageOf(values['state']);
      _retries = (values['num_retries'] as num?)?.toInt() ?? _retries;
      notifyListeners();
    });
    handle.result.then((result) {
      if (_handle != handle) return;
      final values = result.values;
      final code = values is Map ? (values['error_code'] as num?)?.toInt() : null;
      final success = values is Map ? values['success'] != false : result.succeeded;
      switch (result.status) {
        case ActionStatus.succeeded when success:
          _complete(busy == DockStatus.docking ? DockStatus.docked : DockStatus.undocked);
        case ActionStatus.canceled:
          _complete(DockStatus.canceled);
        default:
          final msg = values is Map ? '${values['error_msg'] ?? ''}'.trim() : '';
          _errorCode = code == 0 ? null : code;
          _complete(DockStatus.failed, detail: dockErrorText(code) ?? (msg.isNotEmpty ? msg : result.error));
      }
    });
    notifyListeners();
    return finished.future;
  }

  /// Stops docking (or undocking). The status becomes canceled right away.
  void cancel() {
    if (!isBusy) return;
    try { _handle?.cancel(); } catch (_) {}
    _complete(DockStatus.canceled);
  }

  void _complete(DockStatus status, {String? detail}) {
    if (!isBusy) return;
    _detach(status);
    _status = status;
    _detail = detail;
    notifyListeners();
  }

  void _detach(DockStatus status) {
    _feedback?.cancel();
    _feedback = null;
    _handle = null;
    final finished = _finished;
    _finished = null;
    if (finished != null && !finished.isCompleted) finished.complete(status);
  }

  void reset() {
    if (isBusy || _status == DockStatus.idle) return;
    _status = DockStatus.idle;
    _detail = null;
    _errorCode = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _detach(DockStatus.failed);
    super.dispose();
  }
}
