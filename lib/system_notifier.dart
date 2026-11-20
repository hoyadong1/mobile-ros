import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'robot_requests.dart';

/// Puts the robot's questions and notices in the phone's notification shade while the app is in the
/// background (in the foreground the workspace shows them itself). Android only for now; tapping a
/// notification opens the app, where the question is waiting.
class SystemRobotNotifier implements RobotNotifier {
  SystemRobotNotifier._();

  static SystemRobotNotifier? _instance;

  /// The notifier for this platform, or null where the app does not post notifications.
  static Future<SystemRobotNotifier?> create() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
    if (_instance != null) return _instance;
    final n = SystemRobotNotifier._();
    try {
      await n._plugin.initialize(settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher')));
    } catch (_) {
      return null;
    }
    return _instance = n;
  }

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _asked = false;

  /// Asks for notification permission the first time the robot actually sends something, while the
  /// app is open and showing it, so the person sees why (not as a bare prompt right after connecting).
  Future<void> _askOnce() async {
    if (_asked || _inBackground) return;
    _asked = true;
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } catch (_) {}
  }
  var _nextNoticeId = 1 << 20;

  static bool get _inBackground => WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed;

  static int _idFor(String requestId) => requestId.hashCode & 0xFFFFF;

  static const _questions = AndroidNotificationDetails('robot_requests', 'Robot questions',
      channelDescription: 'The robot asks you to decide something', importance: Importance.high,
      priority: Priority.high, category: AndroidNotificationCategory.message);
  static const _notices = AndroidNotificationDetails('robot_notices', 'Robot notices',
      channelDescription: 'Things the robot wants you to know', importance: Importance.defaultImportance);

  @override
  Future<void> request(HelpRequest request) async {
    if (!_inBackground) return _askOnce();
    await _plugin.show(id: _idFor(request.id), title: request.title,
        body: [request.message, request.options.join(' / ')].where((s) => s.isNotEmpty).join('\n'),
        notificationDetails: const NotificationDetails(android: _questions), payload: request.id);
  }

  @override
  Future<void> notice(RobotNotice notice) async {
    if (!_inBackground) return _askOnce();
    await _plugin.show(id: _nextNoticeId++, title: notice.title, body: notice.message,
        notificationDetails: const NotificationDetails(android: _notices));
  }

  @override
  Future<void> clear(String requestId) => _plugin.cancel(id: _idFor(requestId));
}
