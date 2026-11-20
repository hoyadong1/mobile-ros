import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/mini_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Map<String, dynamic> _map() => {'op': 'publish', 'topic': '/map', 'msg': {
  'header': {'frame_id': 'map'},
  'info': {'width': 10, 'height': 10, 'resolution': 0.5,
    'origin': {'position': {'x': -2.5, 'y': -2.5, 'z': 0}, 'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1}}},
  'data': List.filled(100, 0),
}};

Map<String, dynamic> _odom(double x, double y) => {'op': 'publish', 'topic': '/odom', 'msg': {
  'header': {'frame_id': 'map'}, 'child_frame_id': 'base_footprint',
  'pose': {'pose': {'position': {'x': x, 'y': y, 'z': 0}, 'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1}}},
}};

/// rosbridge throttles whole TF messages, even when they contain different frame pairs.
class _TfThrottleConnection extends FakeConnection {
  int throttle = 0;
  int? lastTf;

  @override
  void send(Map<String, dynamic> message) {
    super.send(message);
    if (message['op'] == 'subscribe' && message['topic'] == '/tf') {
      throttle = message['throttle_rate'] as int? ?? 0;
    }
  }

  void transformAt(int milliseconds, String parent, String child, double x) {
    if (lastTf != null && milliseconds - lastTf! < throttle) return;
    lastTf = milliseconds;
    events.add({'op': 'publish', 'topic': '/tf', 'msg': {'transforms': [
      {'header': {'frame_id': parent}, 'child_frame_id': child,
        'transform': {'translation': {'x': x, 'y': 0.0, 'z': 0.0},
          'rotation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
    ]}});
  }
}

void main() {
  testWidgets('home 3D selection is remembered without publishing motion or reopening subscriptions', (tester) async {
    SharedPreferences.setMockInitialValues({MiniMap.homeViewKey: true});
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/odom'], 'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry']};
    addTearDown(robot.close);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MiniMap(connection: robot, allow3d: true,
      height: 250, onTap: () => opened++))));
    await tester.pump(); await tester.pump();
    robot.events.add(_map()); robot.events.add(_odom(1, 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('home-map-3d')), findsOneWidget);
    final subscriptions = robot.sent.where((m) => m['op'] == 'subscribe').length;
    await tester.tap(find.text('2D'));
    await tester.pumpAndSettle();
    expect(opened, 0, reason: 'the toggle must not also open navigation');
    expect((await SharedPreferences.getInstance()).getBool(MiniMap.homeViewKey), isFalse);
    expect(robot.sent.where((m) => m['op'] == 'subscribe').length, subscriptions);
    expect(robot.sent.where((m) => m['op'] == 'publish' || m['op'] == 'send_action_goal'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the home map can be moved and brought back to the robot; a tap still opens the map', (tester) async {
    SharedPreferences.setMockInitialValues({MiniMap.homeViewKey: false});
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/odom'], 'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry']};
    addTearDown(robot.close);
    var opened = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MiniMap(connection: robot, allow3d: true,
      height: 250, onTap: () => opened++))));
    await tester.pump(); await tester.pump();
    robot.events.add(_map()); robot.events.add(_odom(1, 1));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.byKey(const Key('home-map-recenter')), findsNothing);
    await tester.drag(find.byKey(const Key('mini-map')), const Offset(60, 30));
    await tester.pump();
    expect(find.byKey(const Key('home-map-recenter')), findsOneWidget, reason: 'moved: a way back to the robot');
    expect(opened, 0, reason: 'a drag looks around, it does not open the map');
    await tester.tap(find.byKey(const Key('home-map-recenter')));
    await tester.pump();
    expect(find.byKey(const Key('home-map-recenter')), findsNothing);
    await tester.tap(find.byKey(const Key('mini-map')), warnIfMissed: false);
    await tester.pump();
    expect(opened, 1);
    expect(robot.sent.where((m) => m['op'] == 'publish'), isEmpty, reason: 'looking around never moves the robot');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('slow map TF survives fast odometry TF on a stationary robot', (tester) async {
    final robot = _TfThrottleConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/odom', '/tf'],
      'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry', 'tf2_msgs/msg/TFMessage']};
    addTearDown(robot.close);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: MiniMap(connection: robot))));
    await tester.pumpAndSettle();
    robot.transformAt(0, 'odom', 'base_footprint', 1);
    robot.transformAt(10, 'map', 'odom', 2);
    robot.transformAt(120, 'odom', 'base_footprint', 1);
    await tester.pump();
    final pose = tester.state<MiniMapState>(find.byType(MiniMap)).robotPose;
    expect(pose, isNotNull, reason: 'the slow map transform must not be discarded between fast odom updates');
    expect(pose!.x, 3);
    await tester.pumpWidget(const SizedBox());
  });

  test('the robot always points up: ahead is up, its left is left', () {
    const size = Size(100, 100), ppm = 10.0;
    for (final yaw in [0.0, math.pi / 2, -2.0]) {
      final robot = Pose2D(1, 2, yaw);
      final ahead = MiniMapPainter.toScreen(1 + math.cos(yaw), 2 + math.sin(yaw), robot, ppm, size);
      expect(ahead.dx, closeTo(50, 1e-9));
      expect(ahead.dy, closeTo(40, 1e-9));
      final left = MiniMapPainter.toScreen(1 - math.sin(yaw), 2 + math.cos(yaw), robot, ppm, size);
      expect(left.dx, closeTo(40, 1e-9));
      expect(left.dy, closeTo(50, 1e-9));
    }
  });

  testWidgets('shown only once a map arrives; finds the robot from odometry; a tap makes it bigger', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/odom'], 'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry']};
    addTearDown(robot.close);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft,
        child: MiniMap(connection: robot)))));
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('mini-map')), findsNothing, reason: 'no map yet');
    expect(robot.sent.where((m) => m['op'] == 'subscribe' && m['topic'] == '/map'), isNotEmpty);
    expect(robot.sent.where((m) => m['op'] == 'advertise' || m['op'] == 'publish'), isEmpty,
        reason: 'it only reads');

    robot.events.add(_map());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50))); // map raster
    await tester.pump();
    expect(find.byKey(const Key('mini-map')), findsOneWidget);
    expect(find.textContaining('Finding the robot'), findsOneWidget);

    robot.events.add(_odom(1, 1));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Finding the robot'), findsNothing);
    expect(tester.state<MiniMapState>(find.byType(MiniMap)).robotPose!.x, 1);
    final small = tester.getSize(find.byKey(const Key('mini-map')));
    await tester.tap(find.byKey(const Key('mini-map')));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const Key('mini-map'))).width, greaterThan(small.width));
    await tester.pumpWidget(const SizedBox());
  });
}
