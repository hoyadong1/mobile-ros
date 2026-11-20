// Measures how the map screens cope with big site maps (warehouse-like: outer walls and shelf rows).
// Run: flutter test tool/large_map_bench_test.dart   (numbers are for this PC's test engine, not a phone)
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/map3d.dart';
import 'package:ros_tester/map_geometry.dart';

/// A [side]×[side] grid at 5 cm: known floor, outer walls, shelf rows every 3 m with gaps.
List<int> warehouse(int side) {
  final cells = List<int>.filled(side * side, 0);
  for (var i = 0; i < side; i++) {
    for (final (r, c) in [(0, i), (side - 1, i), (i, 0), (i, side - 1)]) {
      cells[r * side + c] = 100;
    }
  }
  for (var r = 40; r < side - 40; r += 60) {
    for (var dr = 0; dr < 16; dr++) {
      for (var c = 40; c < side - 40; c++) {
        if ((c ~/ 200).isOdd && c % 200 < 40) continue; // aisles across
        // Shelves: solid edges with ragged scan noise inside, like a real SLAM map.
        cells[(r + dr) * side + c] = dr == 0 || dr == 15 || (c * 7 + dr * 13) % 5 == 0 ? 100 : 0;
      }
    }
  }
  return cells;
}

void main() {
  for (final side in [400, 1000, 2000, 4000]) {
    testWidgets('map ${side * 0.05} m square ($side × $side cells)', (tester) async {
      final cells = warehouse(side);
      final watch = Stopwatch()..start();
      final text = jsonEncode({'op': 'publish', 'topic': '/map', 'msg': {
        'info': {'width': side, 'height': side, 'resolution': 0.05}, 'data': cells}});
      final encodeMs = watch.elapsedMilliseconds;
      watch.reset();
      final decoded = (jsonDecode(text) as Map)['msg']['data'] as List;
      final parseMs = watch.elapsedMilliseconds;
      watch.reset();
      final walls = wallBoxes(decoded.cast<int>(), side, side, 0.05, Pose2D.identity);
      final wallsMs = watch.elapsedMilliseconds;

      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      watch.reset();
      await tester.pumpWidget(MaterialApp(home: Map3DView(image: null, cells: cells, width: side, height: side,
          resolution: 0.05, origin: Pose2D.identity, robot: Pose2D(side * 0.025, side * 0.025, 0))));
      final firstMs = watch.elapsedMilliseconds;
      final frames = <int>[];
      for (var i = 0; i < 3; i++) {
        watch.reset();
        await tester.drag(find.byType(Map3DView), const Offset(40, 0));
        await tester.pump();
        frames.add(watch.elapsedMilliseconds);
      }
      // ignore: avoid_print
      print('BENCH ${side * 0.05}m: json ${(text.length / 1e6).toStringAsFixed(1)} MB '
          '(encode ${encodeMs}ms, parse ${parseMs}ms) · wall boxes ${walls.length} in ${wallsMs}ms · '
          '3D first ${firstMs}ms, orbit frame ${frames.reduce(math.max)}ms');
      await tester.pumpWidget(const SizedBox());
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
