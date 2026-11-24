import 'dart:convert';
import 'dart:typed_data';

import 'incident_recorder.dart';

/// A small MCAP writer (https://mcap.dev/spec): header, schemas, channels, messages, data end, footer.
/// No chunks, no index and no summary — all optional in the format; readers (Foxglove, the `mcap` CLI,
/// rosbag2's MCAP plugin for the JSON channels' metadata) read such a file front to back.
class McapWriter {
  static const magic = [0x89, 0x4D, 0x43, 0x41, 0x50, 0x30, 0x0D, 0x0A]; // \x89MCAP0\r\n

  final _out = BytesBuilder(copy: false);
  int _schemas = 0, _channels = 0;
  final _sequence = <int, int>{};

  McapWriter({String profile = '', String library = 'mobile-ros'}) {
    _out.add(magic);
    _record(0x01, (b) => b..string(profile)..string(library));
  }

  /// A schema; returns its id (from 1).
  int schema(String name, String encoding, List<int> data) {
    final id = ++_schemas;
    _record(0x03, (b) => b..u16(id)..string(name)..string(encoding)..bytes(data));
    return id;
  }

  /// A channel; returns its id (from 0).
  int channel(String topic, String messageEncoding, {int schemaId = 0, Map<String, String> metadata = const {}}) {
    final id = _channels++;
    _record(0x04, (b) => b..u16(id)..u16(schemaId)..string(topic)..string(messageEncoding)..map(metadata));
    return id;
  }

  void message(int channel, DateTime time, List<int> data) {
    final seq = _sequence[channel] = (_sequence[channel] ?? -1) + 1;
    final ns = time.microsecondsSinceEpoch * 1000;
    _record(0x05, (b) => b..u16(channel)..u32(seq)..u64(ns)..u64(ns)..raw(data));
  }

  void metadata(String name, Map<String, String> values) => _record(0x0C, (b) => b..string(name)..map(values));

  /// Ends the file and returns it.
  Uint8List finish() {
    _record(0x0F, (b) => b..u32(0)); // data end; CRC 0 = not computed
    _record(0x02, (b) => b..u64(0)..u64(0)..u32(0)); // footer: no summary
    _out.add(magic);
    return _out.takeBytes();
  }

  void _record(int op, void Function(_Bytes) fill) {
    final body = _Bytes();
    fill(body);
    final content = body.done();
    _out.add([op]);
    _out.add((_Bytes()..u64(content.length)).done());
    _out.add(content);
  }
}

class _Bytes {
  final _b = BytesBuilder(copy: false);

  void _fixed(int size, void Function(ByteData) set) {
    final d = ByteData(size);
    set(d);
    _b.add(d.buffer.asUint8List());
  }

  void u16(int v) => _fixed(2, (d) => d.setUint16(0, v, Endian.little));
  void u32(int v) => _fixed(4, (d) => d.setUint32(0, v, Endian.little));
  // Two 32-bit halves: ByteData.setUint64 is missing in browser builds.
  void u64(int v) => _fixed(8, (d) => d
    ..setUint32(0, v & 0xFFFFFFFF, Endian.little)
    ..setUint32(4, (v ~/ 0x100000000) & 0xFFFFFFFF, Endian.little));
  void raw(List<int> v) => _b.add(v);
  void bytes(List<int> v) { u32(v.length); _b.add(v); }
  void string(String s) => bytes(utf8.encode(s));
  void map(Map<String, String> m) {
    final inner = _Bytes();
    for (final e in m.entries) {
      inner..string(e.key)..string(e.value);
    }
    bytes(inner.done());
  }

  Uint8List done() => _b.takeBytes();
}

const _time = {
  'type': 'object',
  'properties': {'sec': {'type': 'integer', 'minimum': 0}, 'nsec': {'type': 'integer', 'minimum': 0}},
};

Map<String, Object?> _stamp(DateTime t) {
  final us = t.microsecondsSinceEpoch;
  return {'sec': us ~/ 1000000, 'nsec': (us % 1000000) * 1000};
}

/// An incident as an MCAP file that Foxglove opens directly:
/// - `/incident/pose` (foxglove.PoseInFrame, frame "odom"): where the robot was,
/// - `/incident/log` (foxglove.Log): every other event as a log line, warnings and errors at their level,
/// - `/incident/events` (mobile_ros.IncidentEvent): the events as the app keeps them, kind included.
/// The robot, the reason and the save time are in the file's metadata.
Uint8List incidentToMcap(Incident incident) {
  final w = McapWriter();
  w.metadata('incident', {
    'robot': incident.robot, 'reason': incident.reason, 'time': incident.time.toUtc().toIso8601String(),
    'app': 'Mobile ROS',
  });
  List<int> json(Object o) => utf8.encode(jsonEncode(o));
  final poseSchema = w.schema('foxglove.PoseInFrame', 'jsonschema', json({
    'title': 'foxglove.PoseInFrame', 'type': 'object',
    'properties': {
      'timestamp': _time, 'frame_id': {'type': 'string'},
      'pose': {'type': 'object', 'properties': {
        'position': {'type': 'object', 'properties': {
          'x': {'type': 'number'}, 'y': {'type': 'number'}, 'z': {'type': 'number'}}},
        'orientation': {'type': 'object', 'properties': {
          'x': {'type': 'number'}, 'y': {'type': 'number'}, 'z': {'type': 'number'}, 'w': {'type': 'number'}}},
      }},
    },
  }));
  final logSchema = w.schema('foxglove.Log', 'jsonschema', json({
    'title': 'foxglove.Log', 'type': 'object',
    'properties': {
      'timestamp': _time,
      'level': {'type': 'integer', 'description': '0 unknown, 1 debug, 2 info, 3 warning, 4 error, 5 fatal'},
      'message': {'type': 'string'}, 'name': {'type': 'string'}, 'file': {'type': 'string'},
      'line': {'type': 'integer', 'minimum': 0},
    },
  }));
  final eventSchema = w.schema('mobile_ros.IncidentEvent', 'jsonschema', json({
    'title': 'mobile_ros.IncidentEvent', 'type': 'object',
    'properties': {
      'kind': {'type': 'string', 'enum': [for (final k in IncidentKind.values) k.name]},
      'text': {'type': 'string'}, 'level': {'type': 'string'},
      'x': {'type': 'number'}, 'y': {'type': 'number'},
    },
  }));
  final pose = w.channel('/incident/pose', 'json', schemaId: poseSchema);
  final log = w.channel('/incident/log', 'json', schemaId: logSchema);
  final events = w.channel('/incident/events', 'json', schemaId: eventSchema);
  final sorted = [...incident.events]..sort((a, b) => a.time.compareTo(b.time));
  for (final e in sorted) {
    if (e.kind == IncidentKind.pose && e.x != null && e.y != null) {
      w.message(pose, e.time, json({
        'timestamp': _stamp(e.time), 'frame_id': 'odom',
        'pose': {'position': {'x': e.x, 'y': e.y, 'z': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}},
      }));
      continue;
    }
    w.message(log, e.time, json({
      'timestamp': _stamp(e.time),
      'level': switch (e.level) { 'error' => 4, 'warning' => 3, _ => 2 },
      'message': e.text, 'name': e.kind.name, 'file': '', 'line': 0,
    }));
    w.message(events, e.time, json({
      'kind': e.kind.name, 'text': e.text, 'level': ?e.level, 'x': ?e.x, 'y': ?e.y,
    }));
  }
  return w.finish();
}

/// A file name for an incident: robot and time, safe on every file system.
String incidentFileName(Incident incident) {
  final t = incident.time;
  String two(int n) => n.toString().padLeft(2, '0');
  final robot = incident.robot.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return 'incident_${robot.isEmpty ? 'robot' : robot}_'
      '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}.mcap';
}
