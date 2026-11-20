import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/dds/ros_interfaces.dart';
import 'package:ros_tester/message_schema.dart';

RosInterfaces bundled() =>
    RosInterfaces(Map<String, String>.from(jsonDecode(File('assets/ros2_interfaces.json').readAsStringSync()) as Map));

Object? at(Object? value, String path) {
  for (final part in path.split('.')) {
    value = value is List ? value[int.parse(part)] : (value as Map)[part];
  }
  return value;
}

Uint8List hex(String h) => Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

void main() {
  test('left-out float fields encode as 0.0, an explicit null as NaN (rosbridge JSON)', () {
    final codec = CdrCodec(bundled());
    final partial = codec.decode('geometry_msgs/msg/Twist',
        codec.encode('geometry_msgs/msg/Twist', {'angular': {'z': 0.5}}));
    expect(partial['linear'], {'x': 0.0, 'y': 0.0, 'z': 0.0});
    expect(partial['angular'], {'x': 0.0, 'y': 0.0, 'z': 0.5});
    final explicit = codec.decode('geometry_msgs/msg/Vector3',
        codec.encode('geometry_msgs/msg/Vector3', {'x': null, 'y': 1}));
    expect(explicit, {'x': null, 'y': 1.0, 'z': 0.0}, reason: 'NaN decodes as null');
    final covariance = codec.decode('geometry_msgs/msg/PoseWithCovariance',
        codec.encode('geometry_msgs/msg/PoseWithCovariance', {'covariance': [1.0]}))['covariance'] as List;
    expect(covariance.length, 36);
    expect(covariance.skip(1).every((v) => v == 0.0), isTrue, reason: 'a short fixed array is padded with 0.0');
  });

  final interfaces = bundled();
  final codec = CdrCodec(interfaces);

  group('bytes serialized by ROS 2 itself', () {
    final fixtures = (jsonDecode(File('test/fixtures/ros2_cdr.json').readAsStringSync()) as List).cast<Map>();
    for (final f in fixtures) {
      test('${f['type']} decodes and survives re-encoding', () {
        final bytes = hex(f['hex'] as String);
        final msg = codec.decode(f['type'] as String, bytes);
        (f['expect'] as Map).forEach((path, expected) {
          final actual = at(msg, path as String);
          if (expected is double) {
            expect((actual as num).toDouble(), closeTo(expected, 1e-6), reason: path);
          } else {
            expect(actual, expected, reason: path);
          }
        });
        // Fast-CDR leaves whatever was in memory in alignment padding, so compare meaning, not bytes;
        // tool/dds_cdr_check.py confirms ROS 2 itself reads what we encode.
        expect(codec.decode(f['type'] as String, codec.encode(f['type'] as String, msg)), msg);
      });
    }
  });

  test('missing fields take defaults and byte arrays accept base64', () {
    final msg = codec.decode('sensor_msgs/msg/Image',
        codec.encode('sensor_msgs/msg/Image', {'width': 2, 'data': base64Encode([5, 6, 7])}));
    expect(msg['width'], 2);
    expect(msg['encoding'], '');
    expect(msg['data'], [5, 6, 7]);
    expect((msg['header'] as Map)['stamp'], {'sec': 0, 'nanosec': 0});
  });

  test('big-endian samples decode too', () {
    // std_msgs/Int32 = -2 in CDR_BE
    expect(codec.decode('std_msgs/msg/Int32', Uint8List.fromList([0, 0, 0, 0, 0xff, 0xff, 0xff, 0xfe])), {'data': -2});
  });

  test('definitions: constants, bounded types, defaults, services and actions', () {
    final battery = interfaces.spec('sensor_msgs/BatteryState')!;
    expect(battery.constants.map((c) => c.$2), contains('POWER_SUPPLY_STATUS_CHARGING'));
    final custom = parseMessage('demo/msg/Thing', 'demo', '''
# comment
uint8 MODE_A=1  # trailing
string<=8 label "x # not a comment"
float64[<=3] values
int32[4] grid
Status status
''');
    expect(custom.constants.single, ('uint8', 'MODE_A', '1'));
    expect(custom.fields.map((f) => (f.name, f.type, f.arrayLen)).toList(), [
      ('label', 'string', -1),
      ('values', 'float64', 0),
      ('grid', 'int32', 4),
      ('status', 'demo/msg/Status', -1),
    ]);
    expect(custom.fields.first.defaultValue, '"x # not a comment"');
    expect(interfaces.spec('std_srvs/srv/SetBool_Request')!.fields.single.name, 'data');
    expect(interfaces.spec('nav2_msgs/action/NavigateToPose_GetResult_Response')!.fields.map((f) => f.name), ['status', 'result']);
    expect(ddsTypeName('nav_msgs/Odometry'), 'nav_msgs::msg::dds_::Odometry_');
    expect(rosTypeFromDds('nav2_msgs::action::dds_::NavigateToPose_SendGoal_Request_'), 'nav2_msgs/action/NavigateToPose_SendGoal_Request');
  });

  test('rosapi-style typedefs feed the publish form', () {
    final defs = rosapiTypedefs(interfaces, 'geometry_msgs/msg/Twist');
    expect(defs.first['type'], 'geometry_msgs/Twist');
    expect(defs.first['fieldtypes'], ['geometry_msgs/Vector3', 'geometry_msgs/Vector3']);
    final schema = MessageSchema.fromRosapi({'typedefs': defs});
    expect(schema.types.keys, containsAll(['geometry_msgs/Twist', 'geometry_msgs/Vector3']));
    final scan = rosapiTypedefs(interfaces, 'sensor_msgs/msg/LaserScan').first;
    expect(scan['fieldarraylen'], [-1, -1, -1, -1, -1, -1, -1, -1, 0, 0]);
  });
}
