// Writes test/fixtures/ros2_cdr_ours.json: each fixture decoded and re-encoded by the app's CDR codec,
// for tool/dds_cdr_check.py to deserialize with ROS 2 (rclpy).  dart run tool/dds_encode_fixtures.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/dds/ros_interfaces.dart';

void main() {
  final codec = CdrCodec(RosInterfaces(Map<String, String>.from(
      jsonDecode(File('assets/ros2_interfaces.json').readAsStringSync()) as Map)));
  final fixtures = (jsonDecode(File('test/fixtures/ros2_cdr.json').readAsStringSync()) as List).cast<Map>();
  String hex(Uint8List b) => [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  Uint8List bytes(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);
  final out = [
    for (final f in fixtures)
      {'type': f['type'], 'original': f['hex'], 'ours': hex(codec.encode(f['type'] as String, codec.decode(f['type'] as String, bytes(f['hex'] as String))))},
  ];
  File('test/fixtures/ros2_cdr_ours.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(out));
  stdout.writeln('${out.length} encoded');
}
