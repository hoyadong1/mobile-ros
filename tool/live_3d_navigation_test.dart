// ignore_for_file: avoid_print
// Run only through scripts/dev-env/sim_live_test.sh (a fresh Gazebo robot).
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/map3d.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/ros_connection.dart';
import 'live_robot_test.dart' show Observer, waitFor;

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);
  testWidgets('3D floor selection, Nav2 path, arrival and cancel survive tablet to phone resize', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = Observer();
    await tester.runAsync(observer.start);
    addTearDown(() => observer.connection.close());
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: host, port: port,
      initial3d: true, connectionFactory: (a, b) => RosConnection(a, b))));
    MapPageState state() => tester.state<MapPageState>(find.byType(MapVisualizationPage));
    await waitFor(tester, () => state().mapData.isNotEmpty && state().robotPose != null, 'map and TF pose',
      timeout: const Duration(seconds: 40));
    final start = state().robotPose!;
    bool clear(double x, double y) {
      final s = state(), r = (0.35 / state().resolution).ceil();
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          if (mapCellAt(x + dx * s.resolution, y + dy * s.resolution, cells: s.mapData,
              width: s.mapWidth, height: s.mapHeight, resolution: s.resolution, origin: s.origin) != MapCellState.free) {
            return false;
          }
        }
      }
      return true;
    }
    final goal = [for (var i = 0; i < 16; i++)
      Offset(start.x + math.cos(i * math.pi / 8), start.y + math.sin(i * math.pi / 8))]
      .firstWhere((p) => clear(p.dx, p.dy));
    Future<void> tapWorld(Offset world) async {
      final finder = find.byType(Map3DView), view = tester.state<Map3DViewState>(find.byType(Map3DView));
      final box = tester.renderObject<RenderBox>(finder);
      await tester.tapAt(box.localToGlobal(project(view.camera.matrix(box.size), world.dx, world.dy, 0)!));
      await tester.pump(const Duration(milliseconds: 350));
    }
    await waitFor(tester, () => observer.odom != null, 'independent odometry');
    final before = observer.odom!;
    await tapWorld(goal);
    expect(state().navState, NavState.preview);
    expect(state().goal!.x, closeTo(goal.dx, 0.02));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 600)));
    expect(observer.odom!.distanceTo(before), lessThan(0.03), reason: 'a preview never starts motion');
    await tester.ensureVisible(find.byKey(const Key('goal-go')));
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    var sawPath = false, sawFeedback = false;
    await waitFor(tester, () {
      sawPath |= state().path.length > 1;
      sawFeedback |= state().distanceRemaining != null;
      return state().navState != NavState.active;
    }, '3D goal to finish', timeout: const Duration(seconds: 120));
    print('3D result: ${state().navState.name}; path drawn: $sawPath; feedback: $sawFeedback; detail: ${state().resultDetail}');
    expect(state().navState, NavState.succeeded);
    expect(sawPath, isTrue);
    expect(sawFeedback, isTrue);
    expect(state().robotPose!.distanceTo(Pose2D(goal.dx, goal.dy, 0)), lessThan(0.4));

    await tester.tap(find.byKey(const Key('nav-dismiss')));
    await tester.pump();
    await tapWorld(Offset(start.x, start.y));
    await tester.ensureVisible(find.byKey(const Key('goal-go')));
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    await waitFor(tester, () => state().robotPose!.distanceTo(Pose2D(goal.dx, goal.dy, 0)) > 0.15, 'return goal to start');
    final view = tester.state<Map3DViewState>(find.byType(Map3DView));
    await tester.binding.setSurfaceSize(const Size(400, 850));
    await tester.pump(const Duration(milliseconds: 200));
    expect(identical(tester.state<Map3DViewState>(find.byType(Map3DView)), view), isTrue);
    expect(state().navState, NavState.active);
    await tester.ensureVisible(find.byKey(const Key('nav-cancel')));
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
    await waitFor(tester, () => observer.odomSpeed.abs() < 0.02, 'stop after cancel');
    print('3D cancel: ${state().navState.name}; STOP speed ${observer.odomSpeed.toStringAsFixed(3)}');
    expect(state().navState, NavState.canceled);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // WebSocket close has a real handshake and a five-second fallback timer in the widget zone.
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(seconds: 6));
  }, timeout: const Timeout(Duration(minutes: 4)));
}
