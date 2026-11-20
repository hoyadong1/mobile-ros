// Live end-to-end check of the app's real widgets against a running rosbridge robot
// (e.g. scripts/ros2_sim.sh). Not part of `flutter test`; run explicitly:
//   flutter test tool/live_robot_test.dart --dart-define=ROBOT_HOST=172.30.1.17 --dart-define=ROBOT_PORT=9090
// ignore_for_file: avoid_print -- progress output is the point of this manual check
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/foxglove_connection.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';
import 'dds_test_support.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
/// `--dart-define=VIA=zenoh` runs the same checks over the Zenoh connection (robot on rmw_zenoh,
/// ROBOT_HOST = its Zenoh router) instead of rosbridge.
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');
ZenohRosSession? _zenoh;
/// `--dart-define=VIA=foxglove` over foxglove_bridge on FOXGLOVE_PORT (default 8765).
const foxglovePort = String.fromEnvironment('FOXGLOVE_PORT', defaultValue: '8765');
RosConnection openConnection() => switch (via) {
  'zenoh' => _zenoh!.connect(),
  'foxglove' => FoxgloveRosConnection.open(host, foxglovePort, bundledInterfaces()),
  _ => RosConnection(host, port),
};
/// Robot namespace for the reference observer, e.g. `--dart-define=NS=/robot1` with scripts/ros2_ns_sim.sh.
const ns = String.fromEnvironment('NS');

/// Independent observer of the robot, outside the widget under test.
class Observer {
  late final RosConnection connection;
  math.Point<double>? odom;
  double odomSpeed = 0;
  math.Point<double>? amcl;

  /// Call inside tester.runAsync so the socket lives in the real zone, not the fake-async one.
  Future<void> start() async {
    connection = openConnection();
    await connection.ready;
    connection.messages.listen((event) {
      final msg = event['msg'];
      if (msg is! Map) return;
      if (event['topic'] == '$ns/odom') {
        final p = msg['pose']['pose']['position'];
        odom = math.Point((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
        odomSpeed = (msg['twist']['twist']['linear']['x'] as num).toDouble();
      } else if (event['topic'] == '$ns/amcl_pose') {
        final p = msg['pose']['pose']['position'];
        amcl = math.Point((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
      }
    });
    connection.send({'op': 'subscribe', 'topic': '$ns/odom', 'throttle_rate': 100});
    connection.send({'op': 'subscribe', 'topic': '$ns/amcl_pose'});
  }
}

/// Lets real socket I/O run while flushing the widget's (fake-async) microtasks and frames.
Future<void> waitFor(WidgetTester tester, bool Function() done, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out after ${timeout.inSeconds}s waiting for $what');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test stubs out HTTP (and so WebSocket handshakes); this check needs the real network.
  setUpAll(() => HttpOverrides.global = null);
  setUpAll(() async {
    if (via == 'zenoh') _zenoh = await ZenohRosSession.open(router: host, interfaces: bundledInterfaces());
    print('connection: $via');
  });
  tearDownAll(() => _zenoh?.close());

  test('rosapi lists parse like the app pages and the robot is detected as ROS 2', () async {
    final client = openConnection();
    addTearDown(client.close);
    final nodes = List<String>.from((await client.call('/rosapi/nodes'))['nodes'] as List);
    final topics = await client.call('/rosapi/topics');
    final services = List<String>.from((await client.call('/rosapi/services'))['services'] as List);
    final details = await client.call('/rosapi/node_details', {'node': '/amcl'});
    print('nodes=${nodes.length} topics=${(topics['topics'] as List).length} services=${services.length} '
        'amcl publishes ${(details['publishing'] as List).length} topics');
    expect(nodes, contains('/amcl'));
    expect(topics['topics'], containsAll(['/map', '/odom', '/goal_pose', '/cmd_vel']));
    expect(services, isNotEmpty);
    expect(detectRosVersion(topics), RosVersion.ros2);
  });

  testWidgets('control screen shows camera frames, drives with the joystick and stops', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420)); // the control screen is landscape-only
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = Observer();
    late RosConnection channel;
    await tester.runAsync(() async {
      await observer.start();
      channel = openConnection();
      await channel.ready;
    });
    addTearDown(() { channel.close(); observer.connection.close(); });

    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: host, port: port, channel: channel,
        imageConnectionFactory: (_, _) => openConnection())));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty,
        'the robot type picker (no stored profile in tests)');
    expect(find.textContaining('Differential · $ns/cmd_vel'), findsOneWidget, reason: 'suggested from rosapi');
    print('suggested: Differential · $ns/cmd_vel');
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    if (ns.isEmpty) { // the namespaced simulation has no overhead demo camera
      await waitFor(tester, () => find.byKey(const Key('camera-image')).evaluate().isNotEmpty,
          'a decoded frame from the suggested camera topic');
      final frame = tester.widget<RawImage>(find.byKey(const Key('camera-image'))).image!;
      print('camera frame ${frame.width}x${frame.height} shown (topic suggested automatically)');
    }

    await tester.tap(find.byKey(const Key('preset-normal')));
    await waitFor(tester, () => observer.odom != null, '/odom');
    final start = observer.odom!;
    // A real drag on the left stick: up = forward. Held ~2.5 s (heartbeat publishes every 100 ms).
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-left'))));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 20));
    }
    for (var i = 0; i < 25; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final moved = observer.odom!.distanceTo(start);
    print('left stick drove the robot ${moved.toStringAsFixed(2)} m (odom speed ${observer.odomSpeed.toStringAsFixed(2)} m/s)');
    expect(moved, greaterThan(0.2));

    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    await waitFor(tester, () => observer.odomSpeed.abs() < 0.02, 'the robot to stop after STOP');
    final stoppedAt = observer.odom!;
    for (var i = 0; i < 10; i++) { // keep holding the stick: STOP must win until it is released
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(observer.odom!.distanceTo(stoppedAt), lessThan(0.05));
    await gesture.up();
    print('STOP: robot at rest while the stick was still held');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('map screen shows the robot and a tapped goal makes Nav2 drive there', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = Observer();
    await tester.runAsync(observer.start);
    addTearDown(() => observer.connection.close());

    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: host, port: port,
        connectionFactory: (_, _) => openConnection())));
    final mapFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MapPainter);
    MapPainter painter() => tester.widget<CustomPaint>(mapFinder).painter! as MapPainter;
    MapPageState state() => tester.state<MapPageState>(find.byType(MapVisualizationPage));
    await waitFor(tester, () => mapFinder.evaluate().isNotEmpty, 'the /map grid', timeout: const Duration(seconds: 30));
    await waitFor(tester, () => state().rosVersion != null, 'navigation detection');
    print('navigation: ${state().navLabel}, scan ${state().scanTopic}, plan ${state().planTopic}');
    await waitFor(tester, () => painter().showRobot, 'robot pose (TF chain / odom + map->odom)');
    await waitFor(tester, () => painter().scan.isNotEmpty, 'LiDAR points on the map');

    math.Point<double> robotOnMap() => math.Point(painter().robot!.x, painter().robot!.y);
    await waitFor(tester, () => observer.amcl != null, '/amcl_pose', timeout: const Duration(seconds: 10))
        .catchError((_) {}); // amcl_pose is only published on updates; it is a cross-check, not required
    final shown = robotOnMap();
    print('app draws robot at map (${shown.x.toStringAsFixed(2)}, ${shown.y.toStringAsFixed(2)}), '
        '${painter().scan.length} LiDAR points'
        '${observer.amcl == null ? '' : ', AMCL says (${observer.amcl!.x.toStringAsFixed(2)}, ${observer.amcl!.y.toStringAsFixed(2)})'}');
    if (observer.amcl != null) expect(shown.distanceTo(observer.amcl!), lessThan(0.3));

    // Pick a free goal ~1 m away with clearance from obstacles.
    final p = painter();
    bool clear(double x, double y) {
      final local = transformPoint(x - p.origin.x, y - p.origin.y, 0, 0, -p.origin.yaw);
      final cx = (local.x / p.resolution).floor(), cy = (local.y / p.resolution).floor();
      final r = (0.35 / p.resolution).ceil();
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          final gx = cx + dx, gy = cy + dy;
          if (gx < 0 || gy < 0 || gx >= p.width || gy >= p.height || p.mapData[gy * p.width + gx] != 0) return false;
        }
      }
      return true;
    }
    final candidates = [for (var a = 0; a < 16; a++)
      math.Point(shown.x + math.cos(a * math.pi / 8), shown.y + math.sin(a * math.pi / 8))];
    final goal = candidates.firstWhere((c) => clear(c.x, c.y), orElse: () => throw StateError('no free goal near robot'));

    state().centerOnRobot();
    await tester.pump();
    final box = tester.renderObject<RenderBox>(mapFinder);
    final at = box.localToGlobal(state().toCanvas(goal.x, goal.y));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 500));
    final placed = painter().goal!;
    expect(math.Point(placed.x, placed.y).distanceTo(goal), lessThan(0.05), reason: 'tap lands where the map says');
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    expect(find.byKey(const Key('nav-progress')), findsOneWidget);
    print('goal sent to map (${goal.x.toStringAsFixed(2)}, ${goal.y.toStringAsFixed(2)}) via ${state().navMode.name}');

    var sawPath = false, sawFeedback = false;
    await waitFor(tester, () {
      sawPath |= painter().path.length > 1;
      sawFeedback |= state().distanceRemaining != null && state().navMode == NavMode.action && state().navState == NavState.active;
      return state().navState != NavState.active;
    }, 'Nav2 to finish', timeout: const Duration(seconds: 120));
    final end = robotOnMap();
    print('result: ${state().navState.name}; path drawn: $sawPath; feedback: $sawFeedback; robot at '
        '(${end.x.toStringAsFixed(2)}, ${end.y.toStringAsFixed(2)}), ${end.distanceTo(goal).toStringAsFixed(2)} m from goal');
    expect(state().navState, NavState.succeeded);
    expect(find.text('Arrived'), findsOneWidget);
    expect(end.distanceTo(goal), lessThan(0.4));
    expect(sawPath, isTrue);

    // A second goal, cancelled mid-way: the robot must stop and the card must say so.
    final back = shown;
    await tester.tap(find.byKey(const Key('nav-dismiss')));
    await tester.pump();
    await tester.tapAt(box.localToGlobal(state().toCanvas(back.x, back.y)));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    await waitFor(tester, () => robotOnMap().distanceTo(end) > 0.15, 'the robot to start the second goal',
        timeout: const Duration(seconds: 30));
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
    await waitFor(tester, () => find.text('Navigation canceled').evaluate().isNotEmpty, 'cancel confirmation');
    await waitFor(tester, () => observer.odomSpeed.abs() < 0.02, 'the robot to stop after cancel');
    print('cancelled: robot stopped at (${robotOnMap().x.toStringAsFixed(2)}, ${robotOnMap().y.toStringAsFixed(2)}), '
        '${robotOnMap().distanceTo(back).toStringAsFixed(2)} m short of the second goal');
    expect(robotOnMap().distanceTo(back), greaterThan(0.1));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6)); // WebSocket.close() arms a 5 s fake-zone timer
  });
}
