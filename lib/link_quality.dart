import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ros_client.dart';

/// How long a request to the robot takes to come back, measured every few seconds while driving.
///
/// Remote-driving tools show this because a slow link makes the robot react late: a stick released at
/// 800 ms of lag still drives the robot for most of a second. Measured with a cheap rosapi service
/// (`/rosapi/get_time`); when the robot has no rosapi, or the link cannot carry service calls, nothing
/// is shown.
class LinkQuality extends ChangeNotifier {
  LinkQuality(this.ros, {this.every = const Duration(seconds: 4), this.timeout = const Duration(seconds: 3),
      Future<Map<String, dynamic>> Function()? probe, DateTime Function()? clock})
      : _probe = probe ?? (() => ros.callService('/rosapi/get_time')),
        _clock = clock ?? DateTime.now;

  final RosClient ros;
  final Duration every;
  final Duration timeout;
  final Future<Map<String, dynamic>> Function() _probe;
  final DateTime Function() _clock;

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;
  int _failures = 0;

  /// The last round trip in milliseconds, or null before the first answer (or when unsupported).
  int? get lagMs => _lagMs;
  int? _lagMs;

  /// Lag worth telling the person about, and lag that makes driving unsafe.
  static const slowMs = 300, verySlowMs = 800;

  void start() {
    _timer ??= Timer.periodic(every, (_) => measure());
    measure();
  }

  /// One measurement. Public for tests.
  Future<void> measure() async {
    if (_busy || _disposed || ros.isClosed) return;
    _busy = true;
    final started = _clock();
    try {
      await _probe().timeout(timeout);
      _failures = 0;
      _set(_clock().difference(started).inMilliseconds);
    } on TimeoutException {
      _set(timeout.inMilliseconds); // lag beyond what can be measured: shown, and measuring goes on
    } catch (_) {
      // No rosapi (the service is refused at once): stop asking after a few tries.
      if (++_failures >= 3 && _lagMs == null) {
        _timer?.cancel();
        _timer = null;
      }
    } finally {
      _busy = false;
    }
  }

  void _set(int ms) {
    if (_disposed || ms == _lagMs) return;
    _lagMs = ms;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
