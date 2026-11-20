import 'dart:async';
import 'ros_connection.dart';

/// ROS graph names always start with '/'. Both connections normalise topic names this way, so events
/// may name a topic with the slash even when it was requested without one.
String rosName(String name) => name.startsWith('/') ? name : '/$name';

/// Typed helpers over a [RosConnection], so callers stop building rosbridge op maps by hand and
/// filtering the shared event stream themselves.
///
///  - [subscribe]: a stream of one topic's messages; listening subscribes, cancelling unsubscribes.
///  - [advertise]: a [RosPublisher]; advertisements are shared and reference-counted per topic.
///  - [callService]: a service call with the connection's timeout.
///  - [sendActionGoal]: an [ActionHandle] with feedback, a result future and cancel().
///
/// Works the same over rosbridge and the direct ROS 2 connection, since both speak the same ops.
/// The client does not own the connection: [dispose] releases what this client created, and closing
/// the connection stays with whoever opened it.
class RosClient {
  RosClient(this.connection, {this.idPrefix = 'mobile_ros'});

  final RosConnection connection;
  final String idPrefix;

  int _seq = 0;
  final _advertised = <String, _Advertisement>{};
  final _actions = <ActionHandle>{};
  bool _disposed = false;

  bool get isClosed => _disposed || connection.isClosed;

  /// A request id that is unique within this app run.
  String nextId(String kind) => '${idPrefix}_${kind}_${DateTime.now().microsecondsSinceEpoch}_${++_seq}';

  // ------------------------------------------------------------------ topics

  /// Messages published on [topic] (the `msg` part of each event).
  ///
  /// Nothing is sent until the stream is listened to. The stream is broadcast: every listener sees the
  /// same messages, and the subscription is dropped when the last listener cancels. [throttleRate] is
  /// the minimum time between messages in milliseconds (0 = every message). The stream closes when the
  /// connection closes.
  Stream<Map<String, dynamic>> subscribe(String topic, {String? type, int throttleRate = 0, int? queueLength}) {
    final name = rosName(topic);
    final id = nextId('sub');
    StreamSubscription<Map<String, dynamic>>? source;
    late final StreamController<Map<String, dynamic>> controller;
    controller = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () {
        if (isClosed) {
          controller.close();
          return;
        }
        source = connection.messages.listen((event) {
          if (event['op'] != 'publish') return;
          final t = event['topic'], msg = event['msg'];
          if (t is! String || rosName(t) != name || msg is! Map) return;
          controller.add(msg is Map<String, dynamic> ? msg : Map<String, dynamic>.from(msg));
        }, onError: controller.addError, onDone: controller.close);
        _trySend({
          'op': 'subscribe', 'id': id, 'topic': name,
          if (type != null && type.isNotEmpty) 'type': type,
          if (throttleRate > 0) 'throttle_rate': throttleRate,
          'queue_length': ?queueLength,
        });
      },
      onCancel: () {
        source?.cancel();
        source = null;
        if (!connection.isClosed) _trySend({'op': 'unsubscribe', 'id': id, 'topic': name});
      },
    );
    return controller.stream;
  }

  /// A publisher for [topic]. Several publishers on the same topic share one advertisement, which is
  /// withdrawn when the last of them is closed. Advertising a topic again with a different [type]
  /// replaces the old advertisement (the robot accepts one type per topic from us).
  RosPublisher advertise(String topic, String type) {
    if (_disposed) throw StateError('RosClient was disposed');
    final name = rosName(topic);
    final existing = _advertised[name];
    if (existing != null && existing.type == type) {
      existing.users++;
    } else {
      if (existing != null) _trySend({'op': 'unadvertise', 'topic': name});
      connection.send({'op': 'advertise', 'topic': name, 'type': type});
      _advertised[name] = _Advertisement(type);
    }
    return RosPublisher._(this, name, type, _advertised[name]!);
  }

  void _release(String name, _Advertisement ad) {
    if (_advertised[name] != ad) return; // replaced by an advertisement with another type
    if (--ad.users > 0) return;
    _advertised.remove(name);
    if (!connection.isClosed) _trySend({'op': 'unadvertise', 'topic': name});
  }

  // ------------------------------------------------------------------ services

  /// Calls [service] and returns its response values. Throws on failure or timeout.
  Future<Map<String, dynamic>> callService(String service, [Map<String, dynamic> args = const {}]) {
    if (_disposed) return Future.error(StateError('RosClient was disposed'));
    return connection.call(rosName(service), args);
  }

  // ------------------------------------------------------------------ actions

  /// Sends a goal to [action] (e.g. `/navigate_to_pose`, type `nav2_msgs/action/NavigateToPose`).
  ///
  /// The handle reports feedback while the goal runs and completes [ActionHandle.result] exactly once:
  /// with the goal's final status, or with [ActionStatus.failed] if the goal could not be sent, was
  /// rejected, or the connection closed first. It never throws.
  ActionHandle sendActionGoal(String action, String type, Map<String, dynamic> args, {bool feedback = true}) {
    final handle = ActionHandle._(this, nextId('goal'), rosName(action));
    if (isClosed) {
      handle._finish(const ActionResult(ActionStatus.failed, error: 'Not connected to the robot.'));
      return handle;
    }
    _actions.add(handle);
    handle._source = connection.messages.listen(handle._onEvent,
        onDone: () => handle._finish(const ActionResult(ActionStatus.failed, error: 'Robot connection closed.')));
    try {
      connection.send({'op': 'send_action_goal', 'id': handle.id, 'action': handle.action,
        'action_type': type, 'feedback': feedback, 'args': args});
    } catch (error) {
      handle._finish(ActionResult(ActionStatus.failed, error: '$error'));
    }
    return handle;
  }

  // ------------------------------------------------------------------ lifecycle

  /// Withdraws this client's advertisements and stops following its goals (their results complete as
  /// [ActionStatus.failed]). Running goals are not cancelled on the robot; call [ActionHandle.cancel]
  /// first if that is wanted. Does not close [connection].
  void dispose() {
    if (_disposed) return;
    for (final handle in _actions.toList()) {
      handle._finish(const ActionResult(ActionStatus.failed, error: 'Stopped following the goal.'));
    }
    if (!connection.isClosed) {
      for (final name in _advertised.keys) {
        _trySend({'op': 'unadvertise', 'topic': name});
      }
    }
    _advertised.clear();
    _disposed = true;
  }

  void _trySend(Map<String, dynamic> message) {
    try {
      connection.send(message);
    } catch (_) {
      // The connection is gone; its own status already reports that.
    }
  }
}

class _Advertisement {
  _Advertisement(this.type);
  final String type;
  int users = 1;
}

/// Publishes on one topic. Obtain it from [RosClient.advertise]; [close] it when done.
class RosPublisher {
  RosPublisher._(this._client, this.topic, this.type, this._ad);

  final RosClient _client;
  final _Advertisement _ad;
  final String topic;
  final String type;
  bool _closed = false;

  bool get isClosed => _closed || _client.isClosed;

  /// Sends [msg]. Throws if this publisher or the connection is closed.
  void publish(Map<String, dynamic> msg) {
    if (_closed) throw StateError('Publisher for $topic was closed');
    _client.connection.send({'op': 'publish', 'topic': topic, 'msg': msg});
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _client._release(topic, _ad);
  }
}

/// Final state of an action goal. The first three follow action_msgs/GoalStatus.
enum ActionStatus {
  succeeded, // 4
  canceled, // 5
  aborted, // 6
  /// Not sent, rejected, transport error, or the connection closed before a result arrived.
  failed,
  /// A result arrived with a status code this app does not interpret.
  unknown,
}

class ActionResult {
  const ActionResult(this.status, {this.code, this.values, this.error});

  final ActionStatus status;
  /// action_msgs/GoalStatus code as reported, if any.
  final int? code;
  /// The action's result message (e.g. NavigateToPose has none worth reading).
  final Object? values;
  /// Why the goal failed, for [ActionStatus.failed].
  final String? error;

  bool get succeeded => status == ActionStatus.succeeded;

  static ActionStatus statusOf(Object? code) => switch (code) {
    4 => ActionStatus.succeeded,
    5 => ActionStatus.canceled,
    6 => ActionStatus.aborted,
    _ => ActionStatus.unknown,
  };

  @override
  String toString() => 'ActionResult(${status.name}${code == null ? '' : ', code $code'}'
      '${error == null ? '' : ', $error'})';
}

/// One goal sent with [RosClient.sendActionGoal].
class ActionHandle {
  ActionHandle._(this._client, this.id, this.action);

  final RosClient _client;
  final String id;
  final String action;
  final _feedback = StreamController<Map<String, dynamic>>.broadcast();
  final _result = Completer<ActionResult>();
  StreamSubscription<Map<String, dynamic>>? _source;
  bool _cancelRequested = false;

  /// Feedback messages while the goal runs; closes when the goal finishes.
  Stream<Map<String, dynamic>> get feedback => _feedback.stream;

  /// Completes once with the final outcome; never completes with an error.
  Future<ActionResult> get result => _result.future;

  bool get isDone => _result.isCompleted;
  bool get cancelRequested => _cancelRequested;

  /// Asks the robot to cancel the goal. The outcome still arrives through [result] (normally
  /// [ActionStatus.canceled]). Does nothing once the goal has finished.
  void cancel() {
    if (isDone || _cancelRequested) return;
    _cancelRequested = true;
    _client._trySend({'op': 'cancel_action_goal', 'id': id, 'action': action});
  }

  void _onEvent(Map<String, dynamic> event) {
    if (event['id'] != id) return;
    switch (event['op']) {
      case 'action_feedback':
        final values = event['values'];
        if (values is Map && !_feedback.isClosed) {
          _feedback.add(values is Map<String, dynamic> ? values : Map<String, dynamic>.from(values));
        }
      case 'action_result':
        final code = (event['status'] as num?)?.toInt();
        if (event['result'] == false) {
          _finish(ActionResult(ActionStatus.failed, code: code, error: '${event['values']}'));
        } else {
          _finish(ActionResult(ActionResult.statusOf(code), code: code, values: event['values']));
        }
      case 'status' when event['level'] == 'error':
        // rosbridge reports a goal it could not send as a status message carrying the request id.
        _finish(ActionResult(ActionStatus.failed, error: '${event['msg']}'));
    }
  }

  void _finish(ActionResult outcome) {
    if (_result.isCompleted) return;
    _result.complete(outcome);
    _source?.cancel();
    _source = null;
    _feedback.close();
    _client._actions.remove(this);
  }
}
