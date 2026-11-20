import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/places.dart';

void main() {
  test('where the robot is: the saved place it is at, else coordinates', () {
    const places = [Place('kitchen', 2, 0), Place('door', 2.6, 0)];
    expect(whereIs(const Pose2D(2.2, 0.1, 0), places), 'At kitchen', reason: 'the nearest one within a metre');
    expect(whereIs(const Pose2D(2.5, 0, 0), places), 'At door');
    expect(whereIs(const Pose2D(-1.24, 0.06, 0), places), 'x -1.2 · y 0.1 m');
  });
}
