// ignore_for_file: avoid_print
// The fleet overview screen on a live fleet (scripts/ros2_jazzy_multi_sim.sh): one map, every robot's
// card with its map position, the task shown while a robot navigates, and the marker following it.
//   FLUTTER=<flutter> DISTRO=jazzy MULTI=1 ROBOTS=4 bash scripts/dev-env/sim_live_test.sh tool/live_fleet_overview_test.dart
//   --dart-define=ROBOTS=4 (default 2), --dart-define=VIA=zenoh for a fleet on rmw_zenoh
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/fleet_overview_page.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';
import 'dds_test_support.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const robotCount = int.fromEnvironment('ROBOTS', defaultValue: 2);
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');

/// Robot start positions in scripts/ros2_jazzy_multi_sim.sh.
const starts = {'robot1': Pose2D(0, 0.5, 0), 'robot2': Pose2D(0, -0.5, 0), 'robot3': Pose2D(-2, -0.5, 0),
  'robot4': Pose2D(-2, 0.5, 0)};

Future<void> waitFor(WidgetTester tester, bool Function() done, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out after ${timeout.inSeconds}s waiting for $what');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

String cardText(WidgetTester tester, String name) => tester
    .widgetList<Text>(find.descendant(of: find.byKey(Key('fleet-$name')), matching: find.byType(Text)))
    .map((t) => t.data).join(' / ');

/// The card's position, or null while it says Unknown.
(double, double)? cardPosition(WidgetTester tester, String name) {
  final m = RegExp(r'Position: (-?[\d.]+), (-?[\d.]+) m').firstMatch(cardText(tester, name));
  return m == null ? null : (double.parse(m[1]!), double.parse(m[2]!));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('the fleet overview shows every robot on one map and follows a navigating one', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late List<RobotSession> robots;
    ZenohRosSession? zenoh;
    late RosConnection connection;
    await tester.runAsync(() async {
      // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
      SharedPreferences.setMockInitialValues({});
      if (via == 'zenoh') {
        zenoh = await ZenohRosSession.open(router: host, interfaces: bundledInterfaces());
        connection = zenoh!.connect();
      } else {
        connection = RosConnection(host, port);
        await connection.ready;
      }
      var names = <String>[];
      for (var i = 0; i < 30 && names.length < robotCount; i++) {
        names = (await RobotCapabilities.discover(connection)).robotNamespaces();
        if (names.length < robotCount) await Future<void>.delayed(const Duration(seconds: 1));
      }
      expect(names, hasLength(robotCount));
      robots = [for (final ns in names) RobotSession(connection: connection, ip: host, port: port, namespace: ns)];
      for (final s in robots) { await s.prepare(); }
    });

    await tester.pumpWidget(MaterialApp(home: FleetOverviewPage(sessions: robots)));
    await waitFor(tester, () => find.byKey(const Key('fleet-map')).evaluate().isNotEmpty, 'the map');
    await waitFor(tester, () => robots.every((s) => cardPosition(tester, s.name) != null), 'every robot position');
    for (final s in robots) {
      final (x, y) = cardPosition(tester, s.name)!;
      final start = starts[s.name]!;
      print('  ${cardText(tester, s.name)}  (spawned at ${start.x}, ${start.y})');
      expect((x - start.x).abs(), lessThan(0.35), reason: '${s.name} is shown where it stands');
      expect((y - start.y).abs(), lessThan(0.35), reason: '${s.name} is shown where it stands');
      expect(cardText(tester, s.name), contains('Current task: Idle'));
    }

    // The last robot navigates 0.8 m along +x: its card shows the task and its position follows.
    final mover = robots.last;
    final (x0, y0) = cardPosition(tester, mover.name)!;
    late Future<NavStatus> going;
    await tester.runAsync(() async { going = mover.nav.goTo(Pose2D(x0 + 0.8, y0, 0)); });
    await waitFor(tester, () => cardText(tester, mover.name).contains('Current task: Navigating'), 'the task');
    print('  while moving: ${cardText(tester, mover.name)}');
    late NavStatus status;
    await tester.runAsync(() async { status = await going.timeout(const Duration(minutes: 2)); });
    expect(status, NavStatus.succeeded);
    // AMCL reports a new pose only every 25 cm of travel, so the last one may fall short of the goal.
    await waitFor(tester, () => (cardPosition(tester, mover.name)!.$1 - x0) > 0.3, 'the marker to follow');
    await waitFor(tester, () => cardText(tester, mover.name).contains('Current task: Idle'), 'the task to end');
    print('  arrived: ${cardText(tester, mover.name)}');
    for (final s in robots.take(robots.length - 1)) {
      expect(cardText(tester, s.name), contains('Current task: Idle'));
    }

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      for (final s in robots) { s.dispose(); }
      connection.close();
      zenoh?.close();
    });
  }, timeout: const Timeout(Duration(minutes: 4)));
}
