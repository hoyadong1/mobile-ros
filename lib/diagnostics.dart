import 'dart:convert';

/// The robot's own health reports: `diagnostic_msgs/DiagnosticArray` on /diagnostics (each driver's
/// diagnostic_updater) or /diagnostics_agg (diagnostic_aggregator, names like "/Robot/Motors/Left").
/// Every report carries a level (OK, WARN, ERROR, STALE), a message and key/value details; the board keeps
/// the latest per name and calls a report stale when it has not been repeated for a while.

enum DiagLevel { ok, warn, error, stale }

/// The level from a message: `byte` arrives as a number, a one-character string or base64, by bridge.
DiagLevel parseDiagLevel(Object? v) {
  int? n;
  if (v is num) n = v.toInt();
  if (v is String) {
    n = int.tryParse(v);
    if (n == null && v.length == 1) n = v.codeUnitAt(0);
    if (n == null) {
      try {
        final b = base64Decode(v);
        if (b.length == 1) n = b.first;
      } catch (_) {}
    }
  }
  if (v is List && v.length == 1 && v.first is num) n = (v.first as num).toInt();
  return switch (n) { 0 => DiagLevel.ok, 1 => DiagLevel.warn, 2 => DiagLevel.error, 3 => DiagLevel.stale, _ => DiagLevel.stale };
}

class DiagStatus {
  DiagStatus(this.name, this.level, this.message, this.hardwareId, this.values, this.seen);

  final String name;
  final DiagLevel level;
  final String message;
  final String hardwareId;
  final List<(String, String)> values;
  final DateTime seen;

  /// The last part of an aggregated name ("/Robot/Motors/Left" → "Left"), the name itself otherwise.
  String get shortName {
    final parts = name.split('/').where((p) => p.trim().isNotEmpty).toList();
    return parts.isEmpty ? name : parts.last;
  }

  /// The groups above it in an aggregated name ("Robot / Motors"), or '' for a plain name.
  String get group {
    if (!name.startsWith('/')) return '';
    final parts = name.split('/').where((p) => p.trim().isNotEmpty).toList();
    return parts.length < 2 ? '' : parts.sublist(0, parts.length - 1).join(' / ');
  }
}

class DiagnosticsBoard {
  DiagnosticsBoard({this.staleAfter = const Duration(seconds: 10)});

  /// diagnostic_updater repeats every second; a report not repeated for this long is shown as stale.
  final Duration staleAfter;
  final _byName = <String, DiagStatus>{};

  bool get isEmpty => _byName.isEmpty;

  /// Takes one DiagnosticArray; returns the reports in it.
  List<DiagStatus> update(Object? msg, DateTime now) {
    if (msg is! Map) return const [];
    final out = <DiagStatus>[];
    for (final s in (msg['status'] as List? ?? const [])) {
      if (s is! Map) continue;
      final name = '${s['name'] ?? ''}'.trim();
      if (name.isEmpty) continue;
      final status = DiagStatus(name, parseDiagLevel(s['level']), '${s['message'] ?? ''}', '${s['hardware_id'] ?? ''}', [
        for (final kv in (s['values'] as List? ?? const [])) if (kv is Map) ('${kv['key'] ?? ''}', '${kv['value'] ?? ''}'),
      ], now);
      _byName[name] = status;
      out.add(status);
    }
    return out;
  }

  /// The level as shown: what the robot said, or stale when it stopped saying it.
  DiagLevel levelOf(DiagStatus s, DateTime now) => now.difference(s.seen) > staleAfter ? DiagLevel.stale : s.level;

  /// Worst first (errors, warnings, stale, OK), then by name.
  List<DiagStatus> sorted(DateTime now) {
    int rank(DiagLevel l) => switch (l) { DiagLevel.error => 0, DiagLevel.warn => 1, DiagLevel.stale => 2, DiagLevel.ok => 3 };
    return _byName.values.toList()
      ..sort((a, b) {
        final r = rank(levelOf(a, now)).compareTo(rank(levelOf(b, now)));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
  }

  Map<DiagLevel, int> counts(DateTime now) {
    final c = {for (final l in DiagLevel.values) l: 0};
    for (final s in _byName.values) {
      c[levelOf(s, now)] = c[levelOf(s, now)]! + 1;
    }
    return c;
  }
}

/// The diagnostics topic to read among the robot's topics: the aggregated one when there is one.
String? pickDiagnosticsTopic(Map<String, String> topicTypes) {
  final all = [for (final e in topicTypes.entries)
    if (e.value.replaceFirst('/msg/', '/') == 'diagnostic_msgs/DiagnosticArray') e.key]..sort();
  return all.where((t) => t.endsWith('diagnostics_agg')).firstOrNull ?? all.where((t) => t.endsWith('/diagnostics')).firstOrNull
      ?? all.firstOrNull;
}

/// Turns reports into "news" for alerts: an error is announced once, again only after it was fine.
class DiagnosticsAlerts {
  final _announced = <String>{};

  /// The reports that just became errors.
  List<DiagStatus> newErrors(List<DiagStatus> reports) {
    final fresh = <DiagStatus>[];
    for (final s in reports) {
      if (s.level == DiagLevel.error) {
        if (_announced.add(s.name)) fresh.add(s);
      } else if (s.level == DiagLevel.ok) {
        _announced.remove(s.name);
      }
    }
    return fresh;
  }
}
