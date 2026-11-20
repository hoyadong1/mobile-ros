/// Notices when a direct connection (DDS, Zenoh) has silently lost the robot.
///
/// rosbridge runs over a WebSocket, which closes when the link drops. Direct connections have no such
/// signal: a phone that walks out of Wi-Fi range just stops receiving, and DDS only forgets the robot
/// after its lease runs out (20 s for Fast DDS). This watches the data the screens subscribed to: a topic
/// that arrived steadily (odometry, scans, TF) and then stops together with every other steady topic
/// means the link is gone. A single topic pausing (a path published only while navigating) does not.
library;

class _Stream {
  _Stream(this.lastAt);
  DateTime lastAt;
  int count = 1;

  /// Smoothed time between samples.
  Duration? period;
}

class LinkWatch {
  LinkWatch({
    this.regularPeriod = const Duration(milliseconds: 500),
    this.minSamples = 5,
    this.minSilence = const Duration(milliseconds: 1500),
    this.periods = 5,
  });

  /// A stream counts as steady once it has [minSamples] samples at most this far apart on average (2 Hz).
  final Duration regularPeriod;
  final int minSamples;

  /// A steady stream is overdue after max([minSilence], [periods] × its period) without a sample.
  final Duration minSilence;
  final int periods;

  final _streams = <Object, _Stream>{};
  final _ignored = <Object>{};

  /// Topics that arrive in bursts by nature (the log, parameter changes): a burst can look steady and
  /// the quiet after it like a lost link, so they never count. Matches plain names (`/rosout`), DDS
  /// names (`rt/rosout`) and Zenoh key expressions (`0/rosout/...`).
  static bool isEventTopic(String name) =>
      RegExp(r'(^|/)(rosout|rosout_agg|parameter_events)(/|$)').hasMatch(name);

  /// Never counts stream [key] (see [isEventTopic]).
  void ignore(Object key) {
    _ignored.add(key);
    _streams.remove(key);
  }

  /// Records a sample of stream [key] (a subscription) received at [now]. A key that is a topic name
  /// is skipped when it is an [isEventTopic].
  void sample(Object key, DateTime now) {
    if (_ignored.contains(key) || (key is String && isEventTopic(key))) return;
    final s = _streams[key];
    if (s == null) {
      _streams[key] = _Stream(now);
      return;
    }
    final gap = now.difference(s.lastAt);
    s.period = s.period == null ? gap : Duration(microseconds: (s.period!.inMicroseconds * 0.8 + gap.inMicroseconds * 0.2).round());
    s.lastAt = now;
    s.count++;
  }

  /// Stops watching [key] (unsubscribed, or not being read while nobody looks at it).
  void forget(Object key) => _streams.remove(key);

  bool _steady(_Stream s) => s.count >= minSamples && s.period != null && s.period! <= regularPeriod;

  Duration _allowed(_Stream s) {
    final p = s.period! * periods;
    return p > minSilence ? p : minSilence;
  }

  /// True when at least one steady stream exists and every steady stream is overdue at [now].
  bool silent(DateTime now) {
    final steady = _streams.values.where(_steady).toList();
    return steady.isNotEmpty && steady.every((s) => now.difference(s.lastAt) > _allowed(s));
  }

  /// How long the steady streams have been quiet (the most recent sample among them), for messages.
  Duration quietFor(DateTime now) {
    final steady = _streams.values.where(_steady);
    if (steady.isEmpty) return Duration.zero;
    final last = steady.map((s) => s.lastAt).reduce((a, b) => a.isAfter(b) ? a : b);
    return now.difference(last);
  }
}

/// The message a connection closes with when [LinkWatch.silent] fires.
String lostContactMessage(Duration quiet) =>
    'Lost contact with the robot: no data for ${(quiet.inMilliseconds / 1000).toStringAsFixed(1)} s.';
