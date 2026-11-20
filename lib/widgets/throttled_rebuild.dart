import 'dart:async';
import 'package:material_ui/material_ui.dart';

/// Caps how often a screen rebuilds for streaming data. Robot topics arrive far faster than anyone
/// can read (TF at 30–100 Hz, a dozen sensor feeds at 10 Hz each); rebuilding the whole page for each
/// message burns CPU and battery on a phone for no visible gain.
///
/// Message handlers update their fields directly and call [rebuildSoon] instead of `setState`. The
/// first call after a quiet period rebuilds at once (so a single update shows without delay); further
/// calls within [rebuildInterval] are merged into one rebuild at the end of the interval.
mixin ThrottledRebuild<T extends StatefulWidget> on State<T> {
  /// Minimum time between rebuilds caused by [rebuildSoon].
  Duration get rebuildInterval;

  Timer? _rebuildTimer;
  Stopwatch? _sinceRebuild;

  void rebuildSoon() {
    if (!mounted || _rebuildTimer != null) return;
    final since = _sinceRebuild;
    if (since == null || since.elapsed >= rebuildInterval) {
      _rebuildNow();
    } else {
      _rebuildTimer = Timer(rebuildInterval - since.elapsed, () {
        _rebuildTimer = null;
        if (mounted) _rebuildNow();
      });
    }
  }

  void _rebuildNow() {
    (_sinceRebuild ??= Stopwatch()).reset();
    _sinceRebuild!.start();
    setState(() {});
  }

  @override
  void dispose() {
    _rebuildTimer?.cancel();
    _rebuildTimer = null;
    super.dispose();
  }
}
