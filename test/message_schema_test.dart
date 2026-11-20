import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/message_schema.dart';

void main() {
  test('ROS API definitions normalize names and build nested defaults', () {
    final schema = MessageSchema.fromRosapi({
      'typedefs': [
        {
          'type': 'geometry_msgs/msg/PoseStamped',
          'fieldnames': ['header', 'pose'],
          'fieldtypes': ['std_msgs/Header', 'geometry_msgs/msg/Pose'],
          'fieldarraylen': [-1, -1],
          'examples': ['{}', '{}'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'std_msgs/Header',
          'fieldnames': ['frame_id', 'stamp'],
          'fieldtypes': ['string', 'builtin_interfaces/Time'],
          'fieldarraylen': [-1, -1],
          'examples': ['', '{}'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'builtin_interfaces/Time',
          'fieldnames': ['sec', 'nanosec'],
          'fieldtypes': ['int32', 'uint32'],
          'fieldarraylen': [-1, -1],
          'examples': ['0', '0'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'geometry_msgs/Pose',
          'fieldnames': ['position', 'orientation'],
          'fieldtypes': ['geometry_msgs/Point', 'geometry_msgs/Quaternion'],
          'fieldarraylen': [-1, -1],
          'examples': ['{}', '{}'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'geometry_msgs/Point',
          'fieldnames': ['x', 'y', 'z'],
          'fieldtypes': ['float64', 'float64', 'float64'],
          'fieldarraylen': [-1, -1, -1],
          'examples': ['0.0', '0.0', '0.0'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'geometry_msgs/Quaternion',
          'fieldnames': ['x', 'y', 'z', 'w'],
          'fieldtypes': ['float64', 'float64', 'float64', 'float64'],
          'fieldarraylen': [-1, -1, -1, -1],
          'examples': ['0.0', '0.0', '0.0', '1.0'],
          'constnames': [],
          'constvalues': [],
        },
      ],
    });

    expect(schema.root, 'geometry_msgs/PoseStamped');
    expect(schema.defaults(), {
      'header': {
        'frame_id': '',
        'stamp': {'sec': 0, 'nanosec': 0},
      },
      'pose': {
        'position': {'x': 0.0, 'y': 0.0, 'z': 0.0},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
      },
    });
  });

  test(
    'coercion fills defaults, preserves types, and checks integer ranges',
    () {
      final schema = MessageSchema.fromRosapi({
        'typedefs': [
          {
            'type': 'demo/Status',
            'fieldnames': ['level', 'enabled', 'name', 'samples'],
            'fieldtypes': ['uint8', 'bool', 'string', 'float32'],
            'fieldarraylen': [-1, -1, -1, 0],
            'examples': ['3', 'false', '', ''],
            'constnames': ['STATUS_READY', 'SLOT_TYPES'],
            'constvalues': ['3', 'ignored'],
          },
        ],
      });

      expect(schema.def('demo/msg/Status')!.constants, {'STATUS_READY': '3'});
    expect(schema.numericFieldPaths(), ['level']);
      expect(
        schema.coerce({
          'enabled': 'true',
          'samples': ['1.5', 2],
        }),
        {
          'level': 3,
          'enabled': true,
          'name': '',
          'samples': [1.5, 2.0],
        },
      );
      expect(() => schema.coerce({'level': 256}), throwsFormatException);
      expect(() => schema.coerce({'name': null}), throwsFormatException);
      expect(() => schema.coerce({'unknown': 1}), throwsFormatException);
    },
  );

  test('legacy definitions and echoed ROS messages compare predictably', () {
    final schema = MessageSchema.fromLegacy('demo/Outer', {
      'demo/Outer': {
        'fields': {
          'point': {'x': 'double', 'y': 'double'},
          'labels': 'array<string>',
        },
      },
    });

    expect(
      schema.coerce({
        'point': {'x': '1.25'},
        'labels': ['a', 'b'],
      }),
      {
        'point': {'x': 1.25, 'y': 0.0},
        'labels': ['a', 'b'],
      },
    );
    expect(
      sameMessage({'x': 1.0, 'ok': true}, {'x': 1.00001, 'ok': 1}),
      isTrue,
    );
    expect(sameMessage({'x': 1.0}, {'x': 2.0}), isFalse);
  });
}
