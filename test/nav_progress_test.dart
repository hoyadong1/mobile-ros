import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/nav_progress.dart';

void main() {
  final t0 = DateTime(2026, 11, 19, 10);
  DateTime at(int s) => t0.add(Duration(seconds: s));

  test('a trip that keeps getting closer is never stuck', () {
    final w = NavProgressWatch();
    for (var s = 0; s <= 120; s += 5) {
      expect(w.update(10 - s * 0.05, at(s)), isFalse, reason: '$s s');
    }
  });

  test('no progress for the window: stuck, said once per goal, and again for the next goal', () {
    final w = NavProgressWatch();
    expect(w.update(4.0, at(0)), isFalse);
    expect(w.update(3.95, at(20)), isFalse, reason: 'a few centimetres is not progress');
    expect(w.update(4.02, at(44)), isFalse, reason: 'not yet 45 s');
    expect(w.update(4.0, at(45)), isTrue);
    expect(w.update(4.0, at(60)), isFalse, reason: 'once per goal');
    expect(w.update(null, at(65)), isFalse, reason: 'the goal ended');
    expect(w.update(6.0, at(70)), isFalse);
    expect(w.update(6.0, at(115)), isTrue, reason: 'a new goal is watched afresh');
  });

  test('progress restarts the clock', () {
    final w = NavProgressWatch();
    w.update(5.0, at(0));
    expect(w.update(4.8, at(40)), isFalse);
    expect(w.update(4.8, at(80)), isFalse, reason: '40 s since it last got closer');
    expect(w.update(4.8, at(85)), isTrue);
  });

  test('a new goal sent right after another is watched afresh', () {
    final w = NavProgressWatch();
    expect(w.update(2.0, at(0), goal: 1), isFalse);
    expect(w.update(20.0, at(5), goal: 2), isFalse, reason: 'farther, but a new trip');
    expect(w.update(19.0, at(46), goal: 2), isFalse, reason: 'it is getting closer');
    expect(w.update(19.0, at(92), goal: 2), isTrue);
  });
}
