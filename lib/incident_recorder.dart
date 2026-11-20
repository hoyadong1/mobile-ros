import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

/// "Why did it stop?": the last few minutes around a robot, kept on the phone and saved when something
/// goes wrong (link lost while moving, a stuck or failed trip, a failed routine) or when the person asks.
/// Foxglove's strength is recording and replay; this is the small version a phone can always keep.
///
/// What is kept: where the robot was (odometry, every second or two), what drove it and how (the app's
/// stick, the assistant, a routine, navigation), trip changes, the assistant's steps, robot warnings and
/// errors from /rosout, link events and the app's own notices. No camera pictures: a record is small.

enum IncidentKind { pose, command, nav, ai, log, link, notice, mark }

class IncidentEvent {
  const IncidentEvent(this.time, this.kind, this.text, {this.x, this.y, this.level});

  final DateTime time;
  final IncidentKind kind;
  final String text;
  /// Where the robot was (odometry frame) for [IncidentKind.pose]; also stamped on other events.
  final double? x, y;
  /// For log lines and notices: "warning", "error".
  final String? level;

  Map<String, Object?> toJson() => {
    't': time.toIso8601String(), 'k': kind.name, 'text': text,
    if (x != null) 'x': double.parse(x!.toStringAsFixed(3)),
    if (y != null) 'y': double.parse(y!.toStringAsFixed(3)),
    'level': ?level,
  };

  static IncidentEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final time = DateTime.tryParse('${j['t']}');
    final kind = IncidentKind.values.where((k) => k.name == j['k']).firstOrNull;
    if (time == null || kind == null) return null;
    double? d(Object? v) => v is num ? v.toDouble() : null;
    return IncidentEvent(time, kind, '${j['text'] ?? ''}', x: d(j['x']), y: d(j['y']),
        level: j['level'] is String ? j['level'] as String : null);
  }
}

/// A saved record: why it was saved, for which robot, and the events before it.
class Incident {
  const Incident({required this.robot, required this.reason, required this.time, required this.events, this.id = ''});

  final String id;
  final String robot;
  final String reason;
  final DateTime time;
  final List<IncidentEvent> events;

  Map<String, Object?> toJson() => {
    'version': 1, 'robot': robot, 'reason': reason, 'time': time.toIso8601String(),
    'events': [for (final e in events) e.toJson()],
  };

  static Incident? fromJson(Object? j, {String id = ''}) {
    if (j is! Map || j['version'] != 1) return null;
    final time = DateTime.tryParse('${j['time']}');
    if (time == null) return null;
    return Incident(id: id, robot: '${j['robot'] ?? ''}', reason: '${j['reason'] ?? ''}', time: time,
        events: [for (final e in (j['events'] as List? ?? const [])) ?IncidentEvent.fromJson(e)]);
  }

  /// The robot's path: the positions in order.
  List<(double, double)> get path => [for (final e in events) if (e.kind == IncidentKind.pose) (e.x!, e.y!)];
}

/// Keeps the last [keep] of events in memory (oldest dropped), and makes an [Incident] of them.
class IncidentRecorder {
  IncidentRecorder({this.keep = const Duration(minutes: 5), this.maxEvents = 3000, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final Duration keep;
  final int maxEvents;
  final DateTime Function() _clock;
  final _events = <IncidentEvent>[];
  double? _x, _y;
  DateTime? _lastPoseAt;

  List<IncidentEvent> get events => List.unmodifiable(_events);

  /// A position. Kept when the robot moved 5 cm or more, or every 10 s when it stands still.
  void pose(double x, double y) {
    final now = _clock();
    final moved = _x == null || (x - _x!).abs() + (y - _y!).abs() >= 0.05;
    if (!moved && _lastPoseAt != null && now.difference(_lastPoseAt!) < const Duration(seconds: 10)) return;
    _x = x;
    _y = y;
    _lastPoseAt = now;
    _add(IncidentEvent(now, IncidentKind.pose, '', x: x, y: y));
  }

  /// Anything else; stamped with the last known position.
  void record(IncidentKind kind, String text, {String? level}) =>
      _add(IncidentEvent(_clock(), kind, text, x: _x, y: _y, level: level));

  void _add(IncidentEvent e) {
    _events.add(e);
    final oldest = e.time.subtract(keep);
    while (_events.isNotEmpty && (_events.first.time.isBefore(oldest) || _events.length > maxEvents)) {
      _events.removeAt(0);
    }
  }

  Incident snapshot(String robot, String reason) =>
      Incident(robot: robot, reason: reason, time: _clock(), events: List.of(_events));
}

/// Saved incidents on the phone, one JSON file each, newest first; the oldest go past [limit].
class IncidentStore {
  IncidentStore({Future<Directory> Function()? folder, this.limit = 30}) : _folder = folder ?? _defaultFolder;

  final Future<Directory> Function() _folder;
  final int limit;

  static Future<Directory> _defaultFolder() async =>
      Directory('${(await getApplicationDocumentsDirectory()).path}/incidents');

  /// A browser has no files to keep records in: nothing is saved there.
  bool get available => !kIsWeb;

  int _sequence = 0;

  /// The saved record, or null where nothing can be saved (the browser).
  Future<Incident?> save(Incident incident) async {
    if (!available) return null;
    final dir = await _folder();
    await dir.create(recursive: true);
    // Several robots can be saved in the same millisecond (link lost while two were moving).
    final id = '${incident.time.millisecondsSinceEpoch}-${(_sequence++ % 1000).toString().padLeft(3, '0')}';
    await File('${dir.path}/$id.json').writeAsString(jsonEncode(incident.toJson()));
    final files = await _files(dir);
    for (final old in files.skip(limit)) {
      try { await old.delete(); } catch (_) {}
    }
    return Incident(id: id, robot: incident.robot, reason: incident.reason, time: incident.time, events: incident.events);
  }

  Future<List<Incident>> list() async {
    if (!available) return const [];
    final dir = await _folder();
    if (!await dir.exists()) return const [];
    return [for (final f in await _files(dir)) ?_read(f)];
  }

  Future<void> delete(String id) async {
    final f = File('${(await _folder()).path}/$id.json');
    if (await f.exists()) await f.delete();
  }

  Incident? _read(File f) {
    try {
      return Incident.fromJson(jsonDecode(f.readAsStringSync()), id: f.uri.pathSegments.last.replaceAll('.json', ''));
    } catch (_) {
      return null;
    }
  }

  Future<List<File>> _files(Directory dir) async {
    final files = [await for (final e in dir.list()) if (e is File && e.path.endsWith('.json')) e];
    files.sort((a, b) => b.path.compareTo(a.path)); // ids are times: newest first
    return files;
  }
}
