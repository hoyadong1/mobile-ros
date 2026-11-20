import 'dart:math' as math;
import 'dart:ui' show Offset;

/// Sensor message types the sensor screen understands, in display order.
enum SensorKind {
  battery('sensor_msgs/BatteryState', 'Battery', 250),
  laser('sensor_msgs/LaserScan', 'LiDAR', 200),
  imu('sensor_msgs/Imu', 'IMU', 100),
  odometry('nav_msgs/Odometry', 'Odometry', 100),
  gps('sensor_msgs/NavSatFix', 'GPS', 250),
  range('sensor_msgs/Range', 'Range', 100),
  temperature('sensor_msgs/Temperature', 'Temperature', 500),
  pressure('sensor_msgs/FluidPressure', 'Pressure', 500),
  humidity('sensor_msgs/RelativeHumidity', 'Humidity', 500),
  custom('', 'Custom', 250);

  const SensorKind(this.type, this.label, this.throttleMs);

  /// ROS 1 style name (`pkg/Type`); ROS 2's `pkg/msg/Type` is normalised to it.
  final String type;
  final String label;
  /// rosbridge throttle: enough for a readable display without flooding the phone.
  final int throttleMs;

  static SensorKind? ofType(String rosType) {
    final t = rosType.replaceFirst('/msg/', '/');
    for (final k in values) {
      if (k.type == t) return k;
    }
    return null;
  }
}

class SensorTopic {
  const SensorTopic(this.topic, this.kind, this.rosType, {this.fieldPath});
  final String topic;
  final SensorKind kind;
  final String rosType; // as rosapi reported it, needed for the subscribe op
  final String? fieldPath;
}

class CustomSensorSource {
  const CustomSensorSource(this.topic, this.rosType, this.fieldPath);
  final String topic;
  final String rosType;
  final String fieldPath;

  Map<String, dynamic> toJson() => {'topic': topic, 'type': rosType, 'field': fieldPath};

  static CustomSensorSource? fromJson(Object? value) {
    if (value is! Map) return null;
    final topic = value['topic'], type = value['type'], field = value['field'];
    if (topic is! String || topic.isEmpty || type is! String || type.isEmpty || field is! String || field.isEmpty) return null;
    return CustomSensorSource(topic, type, field);
  }
}

/// Sensor topics from a /rosapi/topics answer, grouped by kind then name. At most [limit] topics, so a
/// robot with dozens of IMU copies (MAVROS) does not open dozens of subscriptions.
List<SensorTopic> discoverSensors(Map<String, dynamic>? topicsResponse, {int limit = 16}) {
  final names = (topicsResponse?['topics'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
  final types = (topicsResponse?['types'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
  final found = <SensorTopic>[];
  for (var i = 0; i < names.length && i < types.length; i++) {
    final kind = SensorKind.ofType(types[i]);
    if (kind != null) found.add(SensorTopic(names[i], kind, types[i]));
  }
  found.sort((a, b) => a.kind.index != b.kind.index
      ? a.kind.index.compareTo(b.kind.index) : a.topic.compareTo(b.topic));
  return found.take(limit).toList();
}

/// One decoded message, ready to show.
class SensorSample {
  const SensorSample({required this.headline, this.details = const [], this.plot, this.plotUnit = '',
    this.warning, this.scan});
  final String headline;
  final List<(String, String)> details;
  /// The value charted over time (null: no chart point for this message).
  final double? plot;
  final String plotUnit;
  /// Set when the value needs attention (low battery, obstacle close, no GPS fix).
  final String? warning;
  /// LaserScan returns as (x, y) metres in the sensor frame.
  final List<Offset>? scan;
}

/// rosbridge sends NaN and ±inf as null.
double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
/// Fixed decimals without a "-0.00" for values that round to zero.
String _f(double? v, [int digits = 2]) {
  if (v == null) return '—';
  final text = v.toStringAsFixed(digits);
  return double.parse(text) == 0 ? (0.0).toStringAsFixed(digits) : text;
}
double _deg(double rad) => rad * 180 / math.pi;

(double roll, double pitch, double yaw) eulerOf(Map q) {
  final x = (q['x'] as num).toDouble(), y = (q['y'] as num).toDouble();
  final z = (q['z'] as num).toDouble(), w = (q['w'] as num).toDouble();
  final roll = math.atan2(2 * (w * x + y * z), 1 - 2 * (x * x + y * y));
  final sinp = (2 * (w * y - z * x)).clamp(-1.0, 1.0);
  final pitch = math.asin(sinp);
  final yaw = math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
  return (roll, pitch, yaw);
}

SensorSample decodeSensor(SensorKind kind, Map msg, {String? fieldPath}) => switch (kind) {
  SensorKind.battery => _battery(msg),
  SensorKind.laser => _laser(msg),
  SensorKind.imu => _imu(msg),
  SensorKind.odometry => _odometry(msg),
  SensorKind.gps => _gps(msg),
  SensorKind.range => _range(msg),
  SensorKind.temperature => SensorSample(headline: '${_f(_n(msg['temperature']), 1)} °C',
      plot: _n(msg['temperature']), plotUnit: '°C'),
  SensorKind.pressure => () {
      final hpa = _n(msg['fluid_pressure']) == null ? null : _n(msg['fluid_pressure'])! / 100;
      return SensorSample(headline: '${_f(hpa, 1)} hPa', plot: hpa, plotUnit: 'hPa');
    }(),
  SensorKind.humidity => () {
      final pct = _n(msg['relative_humidity']) == null ? null : _n(msg['relative_humidity'])! * 100;
      return SensorSample(headline: '${_f(pct, 0)} %', plot: pct, plotUnit: '%');
    }(),
  SensorKind.custom => _custom(msg, fieldPath),
};

SensorSample _custom(Map msg, String? path) {
  if (path == null || path.isEmpty) throw const FormatException('Custom sensor field is not selected');
  Object? value = msg;
  for (final part in path.split('/')) {
    if (value is! Map || !value.containsKey(part)) throw FormatException('Missing field $path');
    value = value[part];
  }
  final number = _n(value);
  if (number == null) throw FormatException('$path is not a finite number');
  final text = value is int ? '$value' : _f(number); // counters and enums stay whole numbers
  return SensorSample(headline: text, details: [(path, text)], plot: number);
}

const _batteryStatus = ['Unknown', 'Charging', 'Discharging', 'Not charging', 'Full'];

SensorSample _battery(Map m) {
  var pct = _n(m['percentage']);
  if (pct != null && pct > 1.0) pct /= 100; // some drivers report 0..100
  if (pct != null && pct < 0) pct = null; // -1: not measured
  final volts = _n(m['voltage']);
  final status = m['power_supply_status'];
  final statusText = status is int && status >= 0 && status < _batteryStatus.length ? _batteryStatus[status] : '—';
  return SensorSample(
    headline: pct != null ? '${(pct * 100).round()} %' : '${_f(volts)} V',
    details: [('Voltage', '${_f(volts)} V'), ('Current', '${_f(_n(m['current']))} A'), ('Status', statusText)],
    plot: volts, plotUnit: 'V',
    warning: pct != null && pct < 0.2 && status != 1 ? 'Battery low' : null,
  );
}

SensorSample _laser(Map m) {
  final min = (m['angle_min'] as num).toDouble(), inc = (m['angle_increment'] as num).toDouble();
  final rMin = _n(m['range_min']) ?? 0, rMax = _n(m['range_max']) ?? double.infinity;
  final ranges = m['ranges'] as List;
  final points = <Offset>[];
  double? nearest, nearestAngle;
  for (var i = 0; i < ranges.length; i++) {
    final r = _n(ranges[i]);
    if (r == null || r < rMin || r > rMax) continue;
    final a = min + i * inc;
    points.add(Offset(r * math.cos(a), r * math.sin(a)));
    if (nearest == null || r < nearest) { nearest = r; nearestAngle = a; }
  }
  return SensorSample(
    headline: nearest == null ? 'No returns' : 'Nearest ${_f(nearest)} m',
    details: [
      ('Direction', nearestAngle == null ? '—' : '${_deg(nearestAngle).round()}°'),
      ('Returns', '${points.length}/${ranges.length}'),
      ('Range', '${_f(rMin)}–${_f(rMax, 1)} m'),
    ],
    plot: nearest, plotUnit: 'm', scan: points,
    warning: nearest != null && nearest < 0.3 ? 'Obstacle within 0.3 m' : null,
  );
}

SensorSample _imu(Map m) {
  final cov = m['orientation_covariance'];
  final hasOrientation = !(cov is List && cov.isNotEmpty && cov.first == -1) && m['orientation'] is Map;
  final g = m['angular_velocity'] as Map, a = m['linear_acceleration'] as Map;
  final gz = _n(g['z']);
  final acc = [a['x'], a['y'], a['z']].map(_n).toList();
  final accNorm = acc.any((v) => v == null) ? null : math.sqrt(acc.fold<double>(0, (s, v) => s + v! * v));
  String headline = 'Turn rate ${_f(gz == null ? null : _deg(gz), 1)} °/s';
  final details = <(String, String)>[];
  if (hasOrientation) {
    final (roll, pitch, yaw) = eulerOf(m['orientation'] as Map);
    headline = 'Roll ${_f(_deg(roll), 1)}° · Pitch ${_f(_deg(pitch), 1)}°';
    details.add(('Heading', '${_f(_deg(yaw), 0)}°'));
  }
  details
    ..add(('Turn rate', '${_f(gz == null ? null : _deg(gz), 1)} °/s'))
    ..add(('Accel', '${_f(accNorm)} m/s²'));
  return SensorSample(headline: headline, details: details,
      plot: gz == null ? null : _deg(gz), plotUnit: '°/s');
}

SensorSample _odometry(Map m) {
  final pose = m['pose']['pose'] as Map;
  final twist = m['twist']['twist'] as Map;
  final vx = _n(twist['linear']['x']) ?? 0, vy = _n(twist['linear']['y']) ?? 0;
  final wz = _n(twist['angular']['z']) ?? 0;
  final speed = math.sqrt(vx * vx + vy * vy) * (vx < 0 ? -1 : 1);
  final o = pose['orientation'];
  final yaw = o is Map ? eulerOf(o).$3 : 0.0;
  return SensorSample(
    headline: '${_f(speed)} m/s · ${_f(_deg(wz), 0)} °/s',
    details: [
      ('Position', '${_f(_n(pose['position']['x']))}, ${_f(_n(pose['position']['y']))} m'),
      ('Heading', '${_f(_deg(yaw), 0)}°'),
    ],
    plot: speed, plotUnit: 'm/s',
  );
}

const _fixStatus = {-1: 'No fix', 0: 'Fix', 1: 'SBAS fix', 2: 'RTK/GBAS fix'};

SensorSample _gps(Map m) {
  final status = (m['status'] is Map ? m['status']['status'] : null) as int?;
  final lat = _n(m['latitude']), lon = _n(m['longitude']), alt = _n(m['altitude']);
  final noFix = status == null || status < 0 || lat == null || lon == null;
  return SensorSample(
    headline: noFix ? 'No fix' : '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}',
    details: [('Status', _fixStatus[status] ?? '—'), ('Altitude', '${_f(alt, 1)} m')],
    plot: noFix ? null : alt, plotUnit: 'm',
    warning: noFix ? 'No GPS fix' : null,
  );
}

SensorSample _range(Map m) {
  final r = _n(m['range']);
  final lo = _n(m['min_range']), hi = _n(m['max_range']);
  final out = r == null || (lo != null && r < lo) || (hi != null && r > hi);
  return SensorSample(
    headline: out ? 'Out of range' : '${_f(r)} m',
    details: [
      ('Type', m['radiation_type'] == 1 ? 'Infrared' : m['radiation_type'] == 0 ? 'Ultrasound' : '—'),
      ('Limits', '${_f(lo)}–${_f(hi)} m'),
    ],
    plot: out ? null : r, plotUnit: 'm',
  );
}
