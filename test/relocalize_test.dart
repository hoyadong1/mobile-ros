import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/relocalize.dart';

/// A room of [w] x [h] cells with a wall border, plus extra wall cells from [walls] (col, row).
List<int> _room(int w, int h, [Iterable<(int, int)> walls = const []]) {
  final cells = List.filled(w * h, 0);
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      if (r == 0 || c == 0 || r == h - 1 || c == w - 1) cells[r * w + c] = 100;
    }
  }
  for (final (c, r) in walls) {
    cells[r * w + c] = 100;
  }
  return cells;
}

/// A 360° laser at [pose] (map frame, origin at 0,0), as points in the robot's own frame.
List<math.Point<double>> _laser(List<int> cells, int w, int h, double res, Pose2D pose, {int beams = 180}) {
  final out = <math.Point<double>>[];
  for (var i = 0; i < beams; i++) {
    final a = i * 2 * math.pi / beams;
    for (var r = 0.05; r < 10; r += res / 4) {
      final x = pose.x + r * math.cos(pose.yaw + a), y = pose.y + r * math.sin(pose.yaw + a);
      final c = (x / res).floor(), row = (y / res).floor();
      if (c < 0 || row < 0 || c >= w || row >= h) break;
      if (cells[row * w + c] >= 65) { out.add(math.Point(r * math.cos(a), r * math.sin(a))); break; }
    }
  }
  return out;
}

void main() {
  group('scanMatch', () {
    // 10 x 10 cells of 1 m; a wall along column 5.
    final cells = [for (var r = 0; r < 10; r++) for (var c = 0; c < 10; c++) c == 5 ? 100 : 0];
    List<math.Point<double>> column(double x) => [for (var y = 0; y < 10; y++) math.Point(x, y + 0.5)];

    test('points on the wall match, points in open floor do not', () {
      expect(scanMatch(column(5.5), cells, 10, 10, 1, Pose2D.identity), 1.0);
      expect(scanMatch(column(1.5), cells, 10, 10, 1, Pose2D.identity), 0.0);
      expect(scanMatch(column(4.5), cells, 10, 10, 1, Pose2D.identity), 1.0, reason: 'one cell of tolerance');
    });

    test('follows the map origin, and says nothing without enough points', () {
      expect(scanMatch(column(7.5), cells, 10, 10, 1, const Pose2D(2, 0, 0)), 1.0);
      expect(scanMatch(column(5.5).take(5).toList(), cells, 10, 10, 1, Pose2D.identity), isNull);
      expect(scanMatch(column(50), cells, 10, 10, 1, Pose2D.identity), isNull, reason: 'all off the map');
    });
  });

  group('findPose', () {
    const res = 0.05;

    test('finds the robot in an L-shaped room from its laser alone', () {
      // 4 m x 3 m with a block cut out of one corner, so every spot looks different.
      const w = 80, h = 60;
      final cells = _room(w, h, [for (var r = 35; r < 60; r++) for (var c = 50; c < 80; c++) (c, r)]);
      const truth = Pose2D(1.2, 0.9, 0.7);
      final guess = findPose(PoseSearch(cells: cells, width: w, height: h, resolution: res,
          origin: Pose2D.identity, scan: _laser(cells, w, h, res, truth)))!;
      expect(guess.pose.distanceTo(truth), lessThan(0.1));
      expect(normalizeAngle(guess.pose.yaw - truth.yaw).abs(), lessThan(5 * math.pi / 180));
      expect(guess.good, isTrue);
      expect(guess.lookalikes, 0);
    });

    test('in a symmetric room it reports lookalikes and picks the one nearest the robot\'s own guess', () {
      const w = 60, h = 60; // a plain 3 m square looks the same turned by 90°
      final cells = _room(w, h);
      const truth = Pose2D(0.8, 1.0, 0.3);
      final scan = _laser(cells, w, h, res, truth);
      final near = findPose(PoseSearch(cells: cells, width: w, height: h, resolution: res,
          origin: Pose2D.identity, scan: scan, prior: const Pose2D(0.9, 1.1, 0.2)))!;
      expect(near.lookalikes, greaterThan(0));
      expect(near.pose.distanceTo(truth), lessThan(0.1));
    });

    test('a map origin that is offset is honoured', () {
      const w = 80, h = 60;
      final cells = _room(w, h, [for (var r = 35; r < 60; r++) for (var c = 50; c < 80; c++) (c, r)]);
      const truth = Pose2D(1.2, 0.9, -2.0);
      final guess = findPose(PoseSearch(cells: cells, width: w, height: h, resolution: res,
          origin: const Pose2D(-10, -10, 0), scan: _laser(cells, w, h, res, truth)))!;
      expect(guess.pose.distanceTo(const Pose2D(-8.8, -9.1, 0)), lessThan(0.1));
    });

    test('nothing to compare: null', () {
      expect(findPose(PoseSearch(cells: _room(20, 20), width: 20, height: 20, resolution: res,
          origin: Pose2D.identity, scan: const [])), isNull);
    });
  });
}
