import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:ros_tester/map3d.dart';
import 'package:ros_tester/map_geometry.dart';

void main() {
  test('destination cells respect a rotated map origin and distinguish walls from unknown floor', () {
    MapCellState at(double x, double y) => mapCellAt(x, y, cells: [0, 100, -1, 0], width: 2, height: 2,
      resolution: 1, origin: const Pose2D(10, -2, 1.5707963267948966));
    expect(at(9.5, -1.5), MapCellState.free);
    expect(at(9.5, -0.5), MapCellState.occupied);
    expect(at(8.5, -1.5), MapCellState.unknown);
    expect(at(1000, 1000), MapCellState.outside);
  });

  test('screen taps project back to the floor across camera angles and screen shapes', () {
    for (final size in [const Size(400, 800), const Size(1200, 700)]) {
      for (final elevation in [0.25, 0.75, 1.45]) {
        for (final azimuth in [-2.0, 0.0, 1.5]) {
          final camera = OrbitCamera(target: Vector3(2, 3, 0), elevation: elevation, azimuth: azimuth);
          final screen = project(camera.matrix(size), 2.2, 3.1, 0)!;
          final hit = groundPoint(camera, size, screen)!;
          expect(hit.dx, closeTo(2.2, 1e-6));
          expect(hit.dy, closeTo(3.1, 1e-6));
        }
      }
    }
    final low = OrbitCamera(target: Vector3.zero(), elevation: 0.2);
    expect(groundPoint(low, const Size(800, 600), const Offset(400, 0)), isNull, reason: 'sky is not a goal');
  });

  testWidgets('a tap selects a floor point while orbiting never selects a destination', (tester) async {
    final selected = <Offset>[];
    await tester.pumpWidget(MaterialApp(home: Map3DView(image: null, cells: List.filled(100, 0),
      width: 10, height: 10, resolution: 1, origin: Pose2D.identity, onGroundTap: selected.add)));
    final finder = find.byType(Map3DView), state = tester.state<Map3DViewState>(find.byType(Map3DView));
    final box = tester.renderObject<RenderBox>(finder);
    final point = project(state.camera.matrix(box.size), 5, 5, 0)!;
    await tester.tapAt(box.localToGlobal(point));
    await tester.pump(const Duration(milliseconds: 350));
    expect(selected.single.dx, closeTo(5, 1e-6));
    selected.clear();
    await tester.drag(finder, const Offset(100, 40));
    await tester.pump();
    expect(selected, isEmpty);
  });

  test('wall cells along a row merge into one box, in map metres', () {
    // 4 x 2 cells of 0.5 m: a wall run of 3 cells on the bottom row, one cell above.
    final cells = [100, 100, 100, 0, 0, 0, 100, -1];
    final boxes = wallBoxes(cells, 4, 2, 0.5, const Pose2D(-1, -2, 0));
    expect(boxes, hasLength(2));
    expect(boxes.first.corners.first, Vector3(-1, -2, 0));
    expect(boxes.first.corners[1], Vector3(0.5, -2, 0), reason: '3 cells wide');
    expect(boxes.last.corners.first, Vector3(0, -1.5, 0));
  });

  test('the camera puts its target in the middle of the screen and hides what is behind it', () {
    final cam = OrbitCamera(target: Vector3(2, 3, 0), distance: 5);
    final m = cam.matrix(const Size(400, 800));
    final centre = project(m, 2, 3, 0)!;
    expect(centre.dx, closeTo(200, 1e-6));
    expect(centre.dy, closeTo(400, 1e-6));
    final eye = cam.eye, behind = eye + (eye - Vector3(2, 3, 0));
    expect(project(m, behind.x, behind.y, behind.z), isNull);
    expect(cam.copyWith(elevation: 3).elevation, OrbitCamera.maxElevation, reason: 'never upside down');
  });

  testWidgets('the 3D view draws and orbits with a drag', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Map3DView(image: null, cells: List.filled(100, 0)..[55] = 100,
        width: 10, height: 10, resolution: 0.1, origin: Pose2D.identity, robot: const Pose2D(0.5, 0.5, 0))));
    final state = tester.state<Map3DViewState>(find.byType(Map3DView));
    final before = state.camera.azimuth;
    await tester.drag(find.byType(Map3DView), const Offset(120, 0));
    await tester.pump();
    expect(state.camera.azimuth, isNot(before));
    expect(find.byKey(const Key('map3d-hint')), findsNothing, reason: 'the hint goes once the view moved');
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved places show as named pins in 3D too', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Map3DView(image: null, cells: List.filled(100, 0),
        width: 10, height: 10, resolution: 0.1, origin: Pose2D.identity, robot: const Pose2D(0.5, 0.5, 0),
        places: const [('Kitchen', Pose2D(0.2, 0.8, 0)), ('Dock', Pose2D(0.8, 0.2, 1))])));
    expect(tester.widget<Map3DView>(find.byType(Map3DView)).places.map((p) => p.$1), ['Kitchen', 'Dock']);
    await tester.drag(find.byType(Map3DView), const Offset(200, 40));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'pins and labels draw from any angle');
  });

  test('a wall several rows tall is one box; a huge noisy map stays within the box budget', () {
    // A 2 x 3 block of wall: one rectangle, not three runs.
    final cells = List<int>.filled(16, 0);
    for (final i in [5, 6, 9, 10, 13, 14]) {
      cells[i] = 100;
    }
    final boxes = wallBoxes(cells, 4, 4, 1, Pose2D.identity);
    expect(boxes, hasLength(1));
    expect(boxes.single.corners[2], Vector3(3, 4, 0));
    // 4000 x 4000 cells of scattered walls (a 200 m site at 5 cm, noisy).
    final big = List<int>.generate(4000 * 4000, (i) => (i * 2654435761) % 97 == 0 ? 100 : 0);
    final coarse = wallBoxes(big, 4000, 4000, 0.05, Pose2D.identity);
    expect(coarse.length, lessThanOrEqualTo(maxWallBoxes));
    expect(coarse, isNotEmpty, reason: 'walls are coarsened, never dropped');
  });

  testWidgets('the whole map fits a portrait phone too: the camera steps back for the narrow width', (tester) async {
    Future<double> distanceAt(Size size) async {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpWidget(MaterialApp(home: Map3DView(key: UniqueKey(), image: null, cells: List.filled(400, 0),
          width: 20, height: 20, resolution: 0.5, origin: Pose2D.identity)));
      return tester.state<Map3DViewState>(find.byType(Map3DView)).camera.distance;
    }
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final landscape = await distanceAt(const Size(1200, 800));
    final portrait = await distanceAt(const Size(400, 860));
    expect(portrait, greaterThan(landscape * 1.8));
  });
}
