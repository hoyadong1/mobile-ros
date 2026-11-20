import 'dart:math' as math;

import 'sensors.dart';

/// Values over time from a topic, for the graph screen: what to plot (fields), and a time buffer.

/// One line on the graph: a name, a unit, and how to read its value from a message.
class PlotField {
  const PlotField({required this.id, required this.label, this.unit = '', required this.read});
  final String id, label, unit;
  final double? Function(Map msg) read;

  @override
  bool operator ==(Object other) => other is PlotField && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// A field of the message by its path (`twist.twist.linear.x`, `position[2]`).
PlotField pathField(String path) => PlotField(id: 'path:$path', label: path, read: (m) => readPath(m, path));

/// A value a sensor card shows (its headline, or a detail by label), read the way the card reads it.
PlotField sensorField(SensorKind kind, String label, {String? fieldPath, bool headline = false, String unit = ''}) =>
    PlotField(id: 'sensor:${kind.name}:${headline ? '' : label}', label: label, unit: unit, read: (m) {
      final s = decodeSensor(kind, m, fieldPath: fieldPath);
      if (headline) return s.plot;
      for (final (l, text) in s.details) {
        if (l == label) return parseShownNumber(text).$1;
      }
      return null;
    });

/// "12.30 V" -> (12.3, 'V'); "45°" -> (45, '°'); "—" -> (null, '').
(double?, String) parseShownNumber(String text) {
  final m = RegExp(r'^\s*([-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?)\s*(.*)$').firstMatch(text);
  if (m == null) return (null, '');
  return (double.tryParse(m.group(1)!), m.group(2)!.trim());
}

/// The number at [path] in a decoded message (`a.b[2].c`), or null.
double? readPath(Object? msg, String path) {
  Object? v = msg;
  for (final part in RegExp(r'([^.\[\]]+)|\[(\d+)\]').allMatches(path)) {
    if (part.group(2) != null) {
      final i = int.parse(part.group(2)!);
      if (v is! List || i >= v.length) return null;
      v = v[i];
    } else {
      if (v is! Map) return null;
      v = v[part.group(1)];
    }
  }
  if (v is bool) return v ? 1 : 0;
  return v is num && v.isFinite ? v.toDouble() : null;
}

/// Every number in a message, by path. Long arrays (scans, images, maps) are skipped: a graph of
/// one of their thousand elements is rarely what anyone wants.
Map<String, double> numericFields(Object? msg, {int maxArray = 12}) {
  final out = <String, double>{};
  void walk(Object? v, String path) {
    if (v is num && v.isFinite) {
      out[path] = v.toDouble();
    } else if (v is bool) {
      out[path] = v ? 1 : 0;
    } else if (v is Map) {
      for (final e in v.entries) {
        walk(e.value, path.isEmpty ? '${e.key}' : '$path.${e.key}');
      }
    } else if (v is List && v.length <= maxArray) {
      for (var i = 0; i < v.length; i++) {
        walk(v[i], '$path[$i]');
      }
    }
  }
  walk(msg, '');
  // Header stamps change every message and say nothing useful as a graph.
  out.removeWhere((k, _) => k.startsWith('header.') || k.endsWith('.stamp.sec') || k.endsWith('.stamp.nanosec'));
  return out;
}

/// Samples per field over the last [keep]; old ones drop off.
class PlotBuffer {
  PlotBuffer({this.keep = const Duration(minutes: 5)});
  final Duration keep;
  final series = <String, List<(DateTime, double)>>{};

  void add(DateTime t, Map msg, Iterable<PlotField> fields) {
    for (final f in fields) {
      final v = f.read(msg);
      if (v == null || !v.isFinite) continue;
      (series[f.id] ??= []).add((t, v));
    }
    final cutoff = t.subtract(keep);
    for (final s in series.values) {
      var drop = 0;
      while (drop < s.length && s[drop].$1.isBefore(cutoff)) {
        drop++;
      }
      if (drop > 0) s.removeRange(0, drop);
    }
  }

  void clear() => series.clear();

  /// Points of [id] within [window] before [now], as (seconds ago, value) with at most [maxPoints]:
  /// when there are more, each bucket keeps its lowest and highest, so spikes are not lost.
  List<(double, double)> points(String id, DateTime now, Duration window, {int maxPoints = 400}) {
    final s = series[id];
    if (s == null || s.isEmpty) return const [];
    final from = now.subtract(window);
    final inside = [for (final (t, v) in s) if (!t.isBefore(from)) (-now.difference(t).inMicroseconds / 1e6, v)];
    if (inside.length <= maxPoints) return inside;
    final buckets = maxPoints ~/ 2;
    final span = window.inMicroseconds / 1e6;
    final out = <(double, double)>[];
    var i = 0;
    for (var b = 0; b < buckets && i < inside.length; b++) {
      final end = -span + span * (b + 1) / buckets;
      (double, double)? lo, hi;
      while (i < inside.length && (inside[i].$1 <= end || b == buckets - 1)) {
        final p = inside[i++];
        if (lo == null || p.$2 < lo.$2) lo = p;
        if (hi == null || p.$2 > hi.$2) hi = p;
      }
      if (lo == null || hi == null) continue;
      if (identical(lo, hi)) {
        out.add(lo);
      } else {
        out.addAll(lo.$1 <= hi.$1 ? [lo, hi] : [hi, lo]);
      }
    }
    return out;
  }

  /// Min, max, average and latest of [id] within [window].
  ({double min, double max, double mean, double last})? stats(String id, DateTime now, Duration window) {
    final s = series[id];
    if (s == null) return null;
    final from = now.subtract(window);
    var n = 0, sum = 0.0, lo = double.infinity, hi = double.negativeInfinity;
    for (final (t, v) in s) {
      if (t.isBefore(from)) continue;
      n++;
      sum += v;
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
    if (n == 0) return null;
    return (min: lo, max: hi, mean: sum / n, last: s.last.$2);
  }
}
