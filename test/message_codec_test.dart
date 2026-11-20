import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/message_codec.dart';

void main() {
  test('Twist retains nested objects and numeric values', () {
    expect(buildRosMessage({
      'linear': {'x': 'double'}, 'angular': {'z': 'double'},
    }, {'linear/x': '0.5', 'angular/z': '-1'}, {}), {
      'linear': {'x': 0.5}, 'angular': {'z': -1.0},
    });
  });

  test('boolean, integer, array, and empty messages preserve JSON types', () {
    expect(buildRosMessage({'enabled': 'boolean', 'count': 'int', 'samples': 'array<double>'},
        {'enabled': 'false', 'count': '3', 'samples': '[1,2.5]'}, {}),
        {'enabled': false, 'count': 3, 'samples': [1.0, 2.5]});
    expect(buildRosMessage({}, {}, {}), isEmpty);
  });

  test('invalid numeric input and integer overflow are rejected', () {
    for (final input in ['', 'hello', 'NaN', 'Infinity']) {
      expect(() => parseRosValue('double', input, 'x', {}), throwsFormatException);
    }
    expect(() => parseRosValue('uint8', '-1', 'x', {}), throwsFormatException);
    expect(() => parseRosValue('uint8', '256', 'x', {}), throwsFormatException);
    expect(() => parseRosValue('int16', '32768', 'x', {}), throwsFormatException);
    expect(() => parseRosValue('bool', 'yes', 'x', {}), throwsFormatException);
    expect(() => parseRosValue('array<double>', '["bad"]', 'x', {}), throwsFormatException);
  });

  test('referenced types and arrays of objects are converted recursively', () {
    final types = <String, dynamic>{'Point': {'fields': {'x': 'double'}}};
    expect(buildRosMessage({'point': 'Point', 'points': 'array<Point>'},
        {'point/x': '2', 'points': '[{"x":3}]'}, types), {
      'point': {'x': 2.0}, 'points': [{'x': 3.0}],
    });
  });

  test('cyclic definitions fail instead of overflowing the stack', () {
    final types = <String, dynamic>{'Loop': {'fields': {'child': 'Loop'}}};
    expect(() => buildRosMessage({'root': 'Loop'}, {}, types), throwsFormatException);
  });

  test('malformed field schemas are rejected before rendering', () {
    expect(() => validateMessageFields({'x': 12}), throwsFormatException);
    expect(() => validateMessageFields({'position/x': 'double'}), throwsFormatException);
    expect(() => validateMessageFields({'position': {'x': 'double'}}), returnsNormally);
  });
}
