import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'ros_client.dart';

/// The robot asking the person something through the phone, over plain topics so it works on every
/// connection (rosbridge, DDS, Zenoh) and needs no custom message package on the robot. Every message
/// is a std_msgs/String holding JSON:
///
/// * `/mobile_ros/ask` (robot → phone): `{"id", "title", "message", "options": [..], "timeout_s", "urgent"}`.
///   The robot repeats it until answered (the phone may have missed it); `{"id", "cancel": true}`
///   withdraws it.
/// * `/mobile_ros/answer` (phone → robot): `{"id", "choice", "index"}`, or `{"id", "dismissed": true}`.
/// * `/mobile_ros/notify` (robot → phone): `{"title", "message", "level": "info"|"warning"|"error"}`.
///
/// A helper for the robot side is in robot_side/mobile_ros_phone.py.
class RobotProtocol {
  static const ask = '/mobile_ros/ask';
  static const answer = '/mobile_ros/answer';
  static const notify = '/mobile_ros/notify';
  static const type = 'std_msgs/String';
}

/// A question from the robot waiting for the person.
class HelpRequest {
  HelpRequest({required this.id, required this.title, required this.message, required this.options,
      this.urgent = false, Duration? timeout, DateTime? received})
      : received = received ?? DateTime.now(),
        timeout = timeout ?? const Duration(minutes: 5);

  final String id;
  final String title;
  final String message;
  /// The answers to choose from, in order (at least one).
  final List<String> options;
  final bool urgent;
  final DateTime received;
  final Duration timeout;

  DateTime get deadline => received.add(timeout);

  /// From an ask message, or null if it is not a valid question.
  static HelpRequest? fromJson(Map json, {DateTime? now}) {
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    final rawOptions = json['options'];
    final options = rawOptions is List
        ? [for (final o in rawOptions) if (o is String && o.trim().isNotEmpty) o.trim()]
        : <String>[];
    final seconds = json['timeout_s'];
    return HelpRequest(
      id: id,
      title: '${json['title'] ?? 'Robot'}'.trim(),
      message: '${json['message'] ?? ''}'.trim(),
      options: options.isEmpty ? const ['OK'] : options.take(6).toList(),
      urgent: json['urgent'] == true,
      timeout: seconds is num && seconds > 0 ? Duration(milliseconds: (seconds * 1000).round()) : null,
      received: now,
    );
  }
}

enum NoticeLevel { info, warning, error }

/// Something the robot wants the person to know.
class RobotNotice {
  RobotNotice(this.title, this.message, this.level, {DateTime? time}) : time = time ?? DateTime.now();
  final String title;
  final String message;
  final NoticeLevel level;
  final DateTime time;
}

/// Shows the robot's questions and notices outside the app (system notifications). The app supplies
/// one; tests and the web use none.
abstract class RobotNotifier {
  Future<void> request(HelpRequest request);
  Future<void> notice(RobotNotice notice);
  Future<void> clear(String requestId);
}

/// Listens for the robot's questions and notices and sends the person's answers back.
class RobotRequests extends ChangeNotifier {
  RobotRequests(this.ros, {this.namespace = '', this.notifier, this.clock = DateTime.now, this.maxNotices = 30});

  final RosClient ros;
  /// The robot's namespace: its questions come on `<ns>/mobile_ros/ask` (and so on).
  final String namespace;
  RobotNotifier? notifier;
  final DateTime Function() clock;
  final int maxNotices;

  final List<HelpRequest> _pending = [];
  final List<RobotNotice> _notices = [];
  /// Answers already sent, by request id: a repeated question gets the same answer again.
  final Map<String, Map<String, Object?>> _answered = {};
  final _newRequests = StreamController<HelpRequest>.broadcast();
  final _newNotices = StreamController<RobotNotice>.broadcast();
  final List<StreamSubscription<Map<String, dynamic>>> _subscriptions = [];
  RosPublisher? _answers;
  Timer? _expiry;
  bool _started = false;

  /// Questions waiting for an answer, oldest first.
  List<HelpRequest> get pending => List.unmodifiable(_pending);
  /// Recent notices, newest last.
  List<RobotNotice> get notices => List.unmodifiable(_notices);
  Stream<HelpRequest> get requests => _newRequests.stream;
  Stream<RobotNotice> get noticeStream => _newNotices.stream;
  bool get started => _started;

  /// Starts listening (once). Errors (e.g. a connection that cannot subscribe) leave it stopped.
  void start() {
    if (_started) return;
    _started = true;
    _answers = ros.advertise('$namespace${RobotProtocol.answer}', RobotProtocol.type);
    _subscriptions
      ..add(ros.subscribe('$namespace${RobotProtocol.ask}', type: RobotProtocol.type).listen(_onAsk, onError: (_) {}))
      ..add(ros.subscribe('$namespace${RobotProtocol.notify}', type: RobotProtocol.type)
          .listen(_onNotify, onError: (_) {}));
    _expiry = Timer.periodic(const Duration(seconds: 1), (_) => _expire());
  }

  static Map? _json(Map<String, dynamic> msg) {
    final data = msg['data'];
    if (data is! String) return null;
    try {
      final v = jsonDecode(data);
      return v is Map ? v : null;
    } catch (_) {
      return null;
    }
  }

  void _onAsk(Map<String, dynamic> msg) {
    final json = _json(msg);
    if (json == null) return;
    final id = json['id'];
    if (id is! String) return;
    if (json['cancel'] == true) {
      _remove(id);
      return;
    }
    final previous = _answered[id];
    if (previous != null) {
      _send(previous); // the robot did not get the answer yet
      return;
    }
    if (_pending.any((r) => r.id == id)) return; // a repeat
    final request = HelpRequest.fromJson(json, now: clock());
    if (request == null) return;
    _pending.add(request);
    notifyListeners();
    _newRequests.add(request);
    notifier?.request(request);
  }

  void _onNotify(Map<String, dynamic> msg) {
    final json = _json(msg);
    if (json == null) return;
    final level = NoticeLevel.values.where((l) => l.name == json['level']).firstOrNull ?? NoticeLevel.info;
    add(RobotNotice('${json['title'] ?? 'Robot'}'.trim(), '${json['message'] ?? ''}'.trim(), level, time: clock()));
  }

  /// A notice the app itself raises about this robot (low battery, link lost while moving, a scheduled
  /// routine that failed): kept with the robot's own notices and shown outside the app, so it is seen
  /// with the screen off too.
  void add(RobotNotice notice) {
    _notices.add(notice);
    if (_notices.length > maxNotices) _notices.removeAt(0);
    notifyListeners();
    _newNotices.add(notice);
    notifier?.notice(notice);
  }

  /// Answers [requestId] with option [index]. False if it is no longer waiting.
  bool answer(String requestId, int index) {
    final request = _pending.where((r) => r.id == requestId).firstOrNull;
    if (request == null || index < 0 || index >= request.options.length) return false;
    return _reply(requestId, {'id': requestId, 'choice': request.options[index], 'index': index});
  }

  /// Declines to answer [requestId]; the robot is told so it can stop waiting.
  bool dismiss(String requestId) {
    if (!_pending.any((r) => r.id == requestId)) return false;
    return _reply(requestId, {'id': requestId, 'dismissed': true});
  }

  bool _reply(String id, Map<String, Object?> answer) {
    _answered[id] = answer;
    if (_answered.length > 100) _answered.remove(_answered.keys.first);
    _send(answer);
    _remove(id);
    return true;
  }

  void _send(Map<String, Object?> answer) {
    try {
      _answers?.publish({'data': jsonEncode(answer)});
    } catch (_) {}
  }

  void _remove(String id) {
    final before = _pending.length;
    _pending.removeWhere((r) => r.id == id);
    if (_pending.length != before) {
      notifier?.clear(id);
      notifyListeners();
    }
  }

  void _expire() {
    final now = clock();
    for (final r in _pending.where((r) => now.isAfter(r.deadline)).toList()) {
      _remove(r.id);
    }
  }

  @override
  void dispose() {
    _expiry?.cancel();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _answers?.close();
    _newRequests.close();
    _newNotices.close();
    super.dispose();
  }
}
