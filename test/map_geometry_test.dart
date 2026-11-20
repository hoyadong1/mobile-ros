import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/map_geometry.dart';

void main() {
  test('top of the screen maps to the upper map boundary', () {
    final top = screenToWorld(0, 0, 200, 100, 20, 10, 0.5, -2, -3, 0);
    final bottom = screenToWorld(0, 100, 200, 100, 20, 10, 0.5, -2, -3, 0);
    expect(top.x, -2);
    expect(top.y, 2);
    expect(bottom.y, -3);
  });

  test('tap and robot marker coordinates agree with rotated map origins', () {
    for (final angle in [0.0, pi / 2, -pi / 3]) {
      final world = screenToWorld(75, 20, 200, 100, 40, 20, 0.05, -4, 8, angle);
      final screen = worldToScreen(world.x, world.y, 200, 100, 40, 20, 0.05, -4, 8, angle);
      expect(screen.x, closeTo(75, 1e-9));
      expect(screen.y, closeTo(20, 1e-9));
    }
  });

  test('map to odom transform applies rotation before translation', () {
    final result = transformPoint(2, 0, 10, -3, pi / 2);
    expect(result.x, closeTo(10, 1e-9));
    expect(result.y, closeTo(-1, 1e-9));
  });

  test('cropping keeps the known part with a margin, and where it starts', () {
    // 6 x 5 grid, unknown except a 2 x 2 block at columns 3-4, rows 1-2.
    final cells = List<int>.filled(30, -1);
    for (final i in [1 * 6 + 3, 1 * 6 + 4, 2 * 6 + 3, 2 * 6 + 4]) {
      cells[i] = 0;
    }
    final c = cropToKnown(cells, 6, 5, margin: 1);
    expect((c.left, c.bottom, c.width, c.height), (2, 0, 4, 4), reason: 'one cell around, clipped at the edges');
    expect(c.cells.length, 16);
    expect(c.cells[1 * 4 + 1], 0, reason: 'cell (3, 1) of the full grid');
    expect(cropToKnown(List.filled(4, -1), 2, 2).width, 2, reason: 'nothing known: the whole grid');
  });
}
