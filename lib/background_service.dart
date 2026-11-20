import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:ui' show Color;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'app_language.dart';
import 'l10n/generated/app_localizations.dart';

/// Keeps the app working with the screen off or another app in front, as an Android foreground service,
/// for as long as it is connected to a robot: Android freezes a background app within seconds (measured
/// on the emulator: the robot link dropped after 30 s in the background), which would end a running
/// routine, a waiting schedule and the robot's questions. The notification says what is going on (a
/// routine's progress, the next scheduled one, or just "connected") and always has a Stop button, as
/// robot and drone apps do.
///
/// The robot connection and the routine runner stay in the app's own isolate; the service only keeps
/// the process alive and carries the notification. Its Stop button comes back here as an action.
abstract class BackgroundPresence {
  /// Shows (or updates) the ongoing notification.
  Future<void> show({required String title, required String text, bool stoppable = false});

  /// Removes it; the app may then be paused by the system when in the background.
  Future<void> hide();

  /// "stop" when the notification's Stop button is pressed.
  Stream<String> get actions;
}

class ForegroundPresence implements BackgroundPresence {
  ForegroundPresence._() {
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  /// One for the app: there is one service, and a workspace closing while the next one opens (Reconnect)
  /// must not stop the new one's notification; one queue keeps their calls in order.
  static final instance = ForegroundPresence._();

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Once, at start-up (before runApp).
  static void initCommunication() {
    if (supported) FlutterForegroundTask.initCommunicationPort();
  }

  final _actions = StreamController<String>.broadcast();
  bool _initialized = false;
  String _last = '';

  void _onData(Object data) {
    if (data is String) _actions.add(data);
  }

  @override
  Stream<String> get actions => _actions.stream;

  void _init() {
    if (_initialized) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'robot_activity',
        channelName: 'Robot activity',
        channelDescription: 'Routines running and schedules waiting while the app is in the background.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
        allowWifiLock: true,
        // Rely on android:stopWithTask in the manifest. The plugin's Dart option installs
        // TrackVisibilityUtils, which also stops the service on an ordinary Activity pause.
      ),
    );
  }

  /// Calls run one after another: progress changes several times a second at the start of a routine,
  /// and a second start while the first is still starting fails and leaves no notification.
  Future<void> _queue = Future<void>.value();
  Future<void> _then(Future<void> Function() step) =>
      _queue = _queue.then((_) => step()).catchError((Object _) {});

  /// Android drops a package's notification updates beyond about 5 a second ("Shedding" in the log; seen
  /// on a phone with a routine repeating every second), and a dropped last update leaves an old "Running"
  /// on screen. So at most one update per [minUpdateGap]; the latest state always follows.
  static const minUpdateGap = Duration(seconds: 2);
  DateTime? _lastPost;
  ({String title, String text, bool stoppable})? _pending;
  Timer? _pendingTimer;

  @override
  Future<void> show({required String title, required String text, bool stoppable = false}) {
    if (!supported) return Future.value();
    _pending = (title: title, text: text, stoppable: stoppable);
    final last = _lastPost;
    final wait = last == null ? Duration.zero : minUpdateGap - DateTime.now().difference(last);
    if (wait > Duration.zero) {
      _pendingTimer ??= Timer(wait, _flush);
      return Future.value();
    }
    return _flush();
  }

  Future<void> _flush() {
    _pendingTimer = null;
    final p = _pending;
    if (p == null) return Future.value();
    _pending = null;
    _lastPost = DateTime.now();
    return _then(() => _post(p.title, p.text, p.stoppable));
  }

  Future<void> _post(String title, String text, bool stoppable) async {
    final key = '$title|$text|$stoppable';
    final running = await FlutterForegroundTask.isRunningService;
    if (running && key == _last) return;
    _last = key;
    _init();
    final buttons = stoppable ? [NotificationButton(id: 'stop', text: appStrings.stop)] : <NotificationButton>[];
    if (!running) await _askForNotifications();
    if (running) {
      await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text,
          notificationButtons: buttons, notificationIcon: _icon);
    } else {
      await FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.connectedDevice],
        notificationTitle: title,
        notificationText: text,
        notificationButtons: buttons,
        notificationIcon: _icon,
        callback: _startHandler,
      );
    }
  }

  @override
  Future<void> hide() {
    if (!supported) return Future.value();
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pending = null;
    _lastPost = null;
    return _then(() async {
      _last = '';
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    });
  }

  /// Android 13+ hides the notification (progress and its Stop button) without permission; the service
  /// still runs. Asked once per app run, when the first connection starts it, while the app is in front.
  static bool _asked = false;
  static Future<void> _askForNotifications() async {
    if (_asked) return;
    _asked = true;
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
    } catch (_) {}
  }

  /// A monochrome robot (res/drawable/ic_stat_robot.xml): the launcher icon shows as a blank circle.
  static const _icon = NotificationIcon(metaDataName: 'com.hoyadong.ros_tester.notification_icon',
      backgroundColor: Color(0xFF087F8C));

  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    _actions.close();
  }
}

@pragma('vm:entry-point')
void _startHandler() => FlutterForegroundTask.setTaskHandler(_PresenceHandler());

/// Runs in the service's isolate: passes the Stop button to the app and opens it when tapped.
class _PresenceHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onNotificationButtonPressed(String id) => FlutterForegroundTask.sendDataToMain(id);

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

/// What the notification should say for the robots' state, or null for no notification (not connected).
/// [running]: (robot, routine name, progress line); [next]: the next scheduled run; [connectedTo]: the
/// robot (or address) while connected.
({String title, String text, bool stoppable})? presenceFor({
  required List<(String robot, String routine, String detail)> running,
  required (String robot, String routine, DateTime at)? next,
  required DateTime now,
  String? connectedTo,
  String battery = '',
  AppLocalizations? strings,
}) {
  if (connectedTo == null) return null;
  final s = strings ?? appStrings;
  final robotLine = battery.isEmpty ? connectedTo : '$connectedTo · $battery';
  if (running.isNotEmpty) {
    final (robot, routine, detail) = running.first;
    return (
      title: running.length == 1 ? '${s.runningNamed(routine)}${robot.isEmpty ? '' : ' · $robot'}'
          : s.presenceRunningMany(running.length),
      text: running.length == 1 ? detail : running.map((r) => '${r.$2}: ${r.$3}').join(' | '),
      stoppable: true,
    );
  }
  if (next != null) {
    final (robot, routine, at) = next;
    String two(int v) => v.toString().padLeft(2, '0');
    final sameDay = at.year == now.year && at.month == now.month && at.day == now.day;
    final when = '${sameDay ? '' : '${at.month}/${at.day} '}${two(at.hour)}:${two(at.minute)}';
    return (title: robot.isEmpty ? robotLine : robot, text: s.presenceNext(routine, when), stoppable: true);
  }
  return (title: robotLine, text: s.presenceConnected, stoppable: true);
}
