import 'dart:async';
import 'dart:io' show File, Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_language.dart';

/// The home screen widget (Android: android/app/src/main/kotlin/.../RobotWidgetProvider.kt): shows what
/// the background notification shows, and its Stop button opens the app with mobileros://stop, which
/// stops every robot. Opening the app for it is on purpose: it works whatever state the app was in,
/// at once, and the person sees that the robot stopped.
class RobotWidget {
  RobotWidget._();

  static bool get supported => !kIsWeb && Platform.isAndroid;
  static const _provider = 'com.example.ros_tester.RobotWidgetProvider';

  static final _actions = StreamController<String>.broadcast();
  static String? _pending;
  static bool _listening = false;
  static String _last = '';
  static Future<void> _updates = Future<void>.value();

  /// "stop", "open", "connect" or `run:ID` (a routine), from a tap on the widget.
  static Stream<String> get actions => _actions.stream;

  /// Once at start-up: picks up a tap that launched the app, and taps while it runs.
  static Future<void> init() async {
    if (!supported || _listening) return;
    _listening = true;
    try {
      final first = await HomeWidget.initiallyLaunchedFromHomeWidget();
      if (first != null) _pending = _action(first);
    } catch (_) {}
    HomeWidget.widgetClicked.listen((uri) {
      if (uri != null && uri.host.isNotEmpty) _actions.add(_action(uri));
    }, onError: (_) {});
  }

  /// `mobileros://run?routine=ID` → `run:ID`.
  static String _action(Uri uri) => uri.host == 'run' ? 'run:${uri.queryParameters['routine'] ?? ''}' : uri.host;

  /// A tap that started the app before anyone listened (e.g. "stop" from a closed app); read once.
  static String? takePending() {
    final p = _pending;
    _pending = null;
    return p;
  }

  /// Writes the robot's state for the widget and redraws it: [battery] ("80 %") when the robot reports
  /// one, and the routine its Run button starts (the one run last) while connected.
  static Future<void> show({required String title, required String text, required bool connected,
      String battery = '', String routineId = '', String routineName = '', bool running = false,
      bool canConnect = false, String detail = '', String where = '', int problems = -1}) {
    if (!supported) return Future.value();
    // Keep each snapshot together; a pending connected update must not overwrite disconnected.
    return _updates = _updates.then((_) async {
      final key = '${appLocale.value}|$title|$text|$detail|$where|$problems|$connected|$battery|$routineId|$routineName|$running|$canConnect';
      if (key == _last) return;
      try {
        await HomeWidget.saveWidgetData<String>('title', title);
        await HomeWidget.saveWidgetData<String>('text', text);
        await HomeWidget.saveWidgetData<String>('detail', detail);
        await HomeWidget.saveWidgetData<String>('where', connected ? where : '');
        // -1: unknown (not shown); 0: no new problems; n: new warnings or errors in the robot log.
        await HomeWidget.saveWidgetData<int>('problems', connected ? problems : -1);
        await HomeWidget.saveWidgetData<String>('updated', _clock());
        await HomeWidget.saveWidgetData<bool>('connected', connected);
        await HomeWidget.saveWidgetData<String>('battery', battery);
        await HomeWidget.saveWidgetData<String>('routine_id', connected ? routineId : '');
        await HomeWidget.saveWidgetData<String>('routine_name', connected ? routineName : '');
        await HomeWidget.saveWidgetData<bool>('running', connected && running);
        await HomeWidget.saveWidgetData<bool>('can_connect', !connected && canConnect);
        // The widget's own words in the app's language (the widget falls back to English).
        final s = appStrings;
        await HomeWidget.saveWidgetData<String>('label_stop', s.stop);
        await HomeWidget.saveWidgetData<String>('label_stop_routine', s.widgetStopRoutine);
        await HomeWidget.saveWidgetData<String>('label_connect', s.connect);
        await HomeWidget.saveWidgetData<String>('label_no_problems', s.noProblems);
        await HomeWidget.saveWidgetData<String>('label_warnings', problems > 0 ? s.widgetNewWarnings(problems) : '');
        await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
        _last = key;
      } catch (_) {}
    });
  }

  static String _clock() {
    final now = DateTime.now();
    return '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
  }

  static String? _mapPath;

  /// The picture of the map around the robot (from the home screen's map) for the widget.
  static Future<void> saveMap(Uint8List png) async {
    if (!supported) return;
    try {
      final dir = await getApplicationSupportDirectory();
      // A new name each time (two alternating files), so the launcher never shows a half-written one.
      _mapFlip = !_mapFlip;
      final path = '${dir.path}/widget_map_${_mapFlip ? 1 : 0}.png';
      await File(path).writeAsBytes(png, flush: true);
      _mapPath = path;
      await HomeWidget.saveWidgetData<String>('map_path', path);
      await HomeWidget.saveWidgetData<String>('updated', _clock());
      await HomeWidget.updateWidget(qualifiedAndroidName: _provider);
    } catch (_) {}
  }

  static bool _mapFlip = false;

  /// No map picture (disconnected, or a robot without a map).
  static Future<void> clearMap() async {
    if (!supported || _mapPath == null) return;
    _mapPath = null;
    try {
      await HomeWidget.saveWidgetData<String>('map_path', '');
    } catch (_) {}
  }

  static const _routineKey = 'widget_routine';

  /// The routine the widget's Run button starts: the one the person ran last.
  static Future<void> rememberRoutine(String id) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_routineKey, id);
    } catch (_) {}
  }

  static Future<String?> rememberedRoutine() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_routineKey);
    } catch (_) {
      return null;
    }
  }

  /// Whether the launcher lets the app add the widget for the person (Android 8+, most launchers).
  static Future<bool> canPin() async {
    if (!supported) return false;
    try {
      return await HomeWidget.isRequestPinWidgetSupported() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Asks the launcher to add the widget (it shows its own confirmation).
  static Future<void> pin() => HomeWidget.requestPinWidget(qualifiedAndroidName: _provider);

  /// Not connected: the robot connected to last, with a Connect button that connects to it again.
  static Future<void> disconnected() async {
    await clearMap();
    final last = await lastRobot();
    await show(title: last ?? 'Mobile ROS', text: appStrings.widgetNotConnected, connected: false, canConnect: last != null);
  }

  static const _robotKey = 'widget_robot';

  /// The robot connected to last, by the name the app found for it, for the disconnected widget.
  static Future<void> rememberRobot(String name) async {
    try {
      await (await SharedPreferences.getInstance()).setString(_robotKey, name);
    } catch (_) {}
  }

  static Future<String?> lastRobot() async {
    try {
      return (await SharedPreferences.getInstance()).getString(_robotKey);
    } catch (_) {
      return null;
    }
  }
}
