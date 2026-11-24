import 'dart:convert';
import 'dart:math' as math;

/// "Is the lidar dead?" — what a robot's topics are doing right now, judged from the messages alone.
///
/// For each watched topic the phone keeps arrival times and a little about the last messages, and says:
/// - how often messages arrive now and how often they usually do (learned while watching),
/// - when the last one came, and whether it is overdue,
/// - whether a sensor's values stopped changing while messages keep coming (a driver re-sending its last
///   reading with fresh timestamps looks alive to every rate check; a real lidar or IMU always jitters),
/// - whether the header time stopped advancing or went backwards.
///
/// One-shot topics (a map, a robot description) send once or rarely: they are never called overdue.

enum TopicCondition {
  /// Nothing received yet.
  waiting,
  ok,
  /// Arriving at well under the usual rate.
  slow,
  /// No message for much longer than usual.
  stale,
  /// Messages keep coming but the sensor values are identical.
  frozen,
  /// The header time repeats or runs backwards.
  badStamp,
}

/// Types whose values always move on a working sensor (noise), so a long run of identical values is a sign
/// of a stuck driver. Odometry, joint states and the like legitimately repeat while the robot stands still.
const noisySensorTypes = {
  'sensor_msgs/LaserScan', 'sensor_msgs/Imu', 'sensor_msgs/MagneticField', 'sensor_msgs/MultiEchoLaserScan',
};

/// Types worth watching by default when they exist on the robot, in this order.
const defaultHealthTypes = [
  'sensor_msgs/LaserScan', 'sensor_msgs/Imu', 'nav_msgs/Odometry', 'sensor_msgs/JointState',
  'sensor_msgs/BatteryState', 'sensor_msgs/NavSatFix', 'sensor_msgs/Range', 'sensor_msgs/MagneticField',
  'tf2_msgs/TFMessage', 'sensor_msgs/Image', 'sensor_msgs/CompressedImage', 'sensor_msgs/PointCloud2',
];

String _plainType(String type) => type.replaceFirst('/msg/', '/');

/// The topics to watch first on a robot: known sensor and state types, at most [max].
List<String> pickHealthTopics(Map<String, String> topicTypes, {int max = 8}) {
  final picked = <String>[];
  for (final want in defaultHealthTypes) {
    final names = topicTypes.keys.where((t) => _plainType(topicTypes[t]!) == want).toList()..sort();
    for (final t in names) {
      if (t == '/tf_static') continue; // sent once: nothing to watch
      if (picked.length >= max) return picked;
      picked.add(t);
    }
  }
  return picked;
}

class TopicHealth {
  TopicHealth(this.topic, String type, {this.limited = false}) : type = _plainType(type);

  final String topic;
  final String type;
  /// Messages arrive throttled (large types, a remote link): the rate is not the robot's, so only
  /// "still arriving" is judged.
  final bool limited;

  static const window = Duration(seconds: 5);

  final _arrivals = <DateTime>[];
  DateTime? first, last;
  int received = 0;
  /// The usual rate (messages per second), learned while watching; null until there is enough to tell.
  double? usualRate;
  DateTime? _lastLearn;

  String? _lastValues;
  int sameValues = 0;
  DateTime? _sameSince;

  ({int sec, int nanosec})? _lastStamp;
  int sameStamps = 0;
  bool stampWentBack = false;

  void onMessage(Object? msg, DateTime now) {
    received++;
    first ??= now;
    last = now;
    _arrivals.add(now);
    _trim(now);
    if (msg is! Map) return;
    final header = msg['header'];
    final stamp = header is Map ? _stamp(header['stamp']) : null;
    if (stamp != null && (stamp.sec != 0 || stamp.nanosec != 0)) {
      final before = _lastStamp;
      if (before != null) {
        final cmp = stamp.sec != before.sec ? stamp.sec.compareTo(before.sec) : stamp.nanosec.compareTo(before.nanosec);
        if (cmp == 0) {
          sameStamps++;
        } else {
          sameStamps = 0;
          stampWentBack = cmp < 0;
        }
      }
      _lastStamp = stamp;
    }
    if (noisySensorTypes.contains(type)) {
      final values = jsonEncode({for (final e in msg.entries) if (e.key != 'header') '${e.key}': e.value});
      if (values == _lastValues) {
        sameValues++;
      } else {
        sameValues = 0;
        _sameSince = now;
        _lastValues = values;
      }
    }
  }

  static ({int sec, int nanosec})? _stamp(Object? s) {
    if (s is! Map) return null;
    final sec = s['sec'] ?? s['secs'];
    final nsec = s['nanosec'] ?? s['nsecs'];
    if (sec is! num || nsec is! num) return null;
    return (sec: sec.toInt(), nanosec: nsec.toInt());
  }

  void _trim(DateTime now) {
    final cutoff = now.subtract(window);
    while (_arrivals.isNotEmpty && _arrivals.first.isBefore(cutoff)) {
      _arrivals.removeAt(0);
    }
  }

  /// Messages per second over the last few seconds (over less while watching has just started).
  double rate(DateTime now) {
    _trim(now);
    final since = first;
    if (since == null) return 0;
    final span = now.difference(since);
    final seconds = (span < window ? span : window).inMilliseconds / 1000;
    if (seconds < 1) return 0;
    return _arrivals.length / seconds;
  }

  /// Called about once a second: learns the usual rate while things look normal.
  void tick(DateTime now) {
    final since = first;
    if (since == null || now.difference(since) < window) return;
    if (_lastLearn != null && now.difference(_lastLearn!) < const Duration(milliseconds: 900)) return;
    _lastLearn = now;
    final r = rate(now);
    final usual = usualRate;
    if (usual == null) {
      if (received >= 3) usualRate = r;
    } else if (r >= usual * 0.7 && now.difference(last!).inMilliseconds < math.max(2000 / usual, 150)) {
      // (Only while messages are on time: just after a topic stops, the falling rate is not "usual".)
      // Follow slow drifts and genuine speed-ups, not dips (a dip is what we want to report).
      usualRate = usual * 0.9 + r * 0.1;
    }
  }

  /// How long after the last message it is overdue: three usual gaps, at least 2 s.
  Duration? get overdueAfter {
    final usual = usualRate;
    if (usual == null || usual <= 0 || received < 3) return null;
    final ms = (3000 / usual).round();
    return Duration(milliseconds: ms < 2000 ? 2000 : ms);
  }

  Duration? sinceLast(DateTime now) => last == null ? null : now.difference(last!);

  /// How long the values have been identical (null when they move or the type is not a noisy sensor).
  Duration? frozenFor(DateTime now) {
    if (sameValues < 10 || _sameSince == null) return null;
    final d = now.difference(_sameSince!);
    return d >= const Duration(seconds: 2) ? d : null;
  }

  TopicCondition condition(DateTime now) {
    if (last == null) return TopicCondition.waiting;
    final overdue = overdueAfter;
    if (overdue != null && now.difference(last!) > overdue) return TopicCondition.stale;
    if (limited && now.difference(last!) > const Duration(seconds: 5) && received >= 3) return TopicCondition.stale;
    if (frozenFor(now) != null) return TopicCondition.frozen;
    if (sameStamps >= 5 || stampWentBack) return TopicCondition.badStamp;
    final usual = usualRate;
    if (!limited && usual != null && usual >= 1 && rate(now) < usual * 0.5) return TopicCondition.slow;
    return TopicCondition.ok;
  }
}
