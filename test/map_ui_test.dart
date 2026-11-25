import 'dart:convert';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/map3d.dart';
import 'support/fake_ros_connection.dart';

final _mapFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MapPainter);
MapPainter _painter(WidgetTester t) => t.widget<CustomPaint>(_mapFinder).painter! as MapPainter;

Map<String, dynamic> _grid({int w = 2, int h = 2, double res = 1.0, List<int>? data}) => {
  'op': 'publish', 'topic': '/map', 'msg': {
    'header': {'frame_id': 'map'},
    'info': {'width': w, 'height': h, 'resolution': res, 'origin': {
      'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
    'data': data ?? List.filled(w * h, 0),
  },
};

Map<String, dynamic> _tf(String parent, String child, double x, double y, [double yaw = 0]) => {
  'header': {'frame_id': parent}, 'child_frame_id': child, 'transform': {
    'translation': {'x': x, 'y': y, 'z': 0.0}, 'rotation': quaternionFromYaw(yaw)}};

Future<void> _open(WidgetTester tester, FakeConnection robot) async {
  await tester.binding.setSurfaceSize(const Size(900, 600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(
    ip: 'robot', port: '9090', connectionFactory: (_, _) => robot)));
  await tester.pump();
}

/// Taps the map centre and presses Go; returns what was sent.
Future<void> _tapAndGo(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(_mapFinder));
  await tester.pump(const Duration(milliseconds: 500)); // past the double-tap/long-press window
  expect(find.byKey(const Key('goal-go')), findsOneWidget);
  await tester.tap(find.byKey(const Key('goal-go')));
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('3D destination selection requires Go and rejects wall destinations', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid(w: 10, h: 10, data: List.filled(100, 0)..[55] = 100));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-layers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-3d-toggle')));
    await tester.pumpAndSettle();
    final finder = find.byType(Map3DView), view = tester.state<Map3DViewState>(find.byType(Map3DView));
    final box = tester.renderObject<RenderBox>(finder);
    Future<void> tapWorld(double x, double y) async {
      await tester.tapAt(box.localToGlobal(project(view.camera.matrix(box.size), x, y, 0)!));
      await tester.pump(const Duration(milliseconds: 350));
    }
    await tapWorld(5.5, 5.5);
    expect(find.textContaining('on a wall or obstacle'), findsOneWidget);
    expect(find.byKey(const Key('goal-go')), findsNothing);
    await tapWorld(4.5, 5.5);
    final state = tester.state<MapPageState>(find.byType(MapVisualizationPage));
    expect(state.goal!.x, closeTo(4.5, 1e-6));
    expect(state.goal!.y, closeTo(5.5, 1e-6));
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/goal_pose'), isEmpty);
    await tester.ensureVisible(find.byKey(const Key('goal-go')));
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    final sent = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/goal_pose');
    expect(sent['msg']['pose']['position']['x'], closeTo(4.5, 1e-6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('phone destination preview wraps coordinates and keeps Go reachable', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.binding.setSurfaceSize(const Size(320, 720));
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    robot.events.add(_grid(w: 4, h: 4));
    await tester.pumpAndSettle();
    final state = tester.state<MapPageState>(find.byType(MapVisualizationPage));
    final mapBox = tester.renderObject<RenderBox>(_mapFinder);
    await tester.tapAt(mapBox.localToGlobal(state.toCanvas(1.5, 1.5)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state.goal, isNotNull, reason: state.errorMessage ?? 'The visible floor tap must select a goal.');
    for (final label in ['X', 'Y']) {
      final text = tester.widget<Text>(find.byKey(Key('goal-metric-$label')));
      expect(text.maxLines, isNull);
      expect(text.overflow, isNot(TextOverflow.ellipsis));
    }
    await tester.ensureVisible(find.byKey(const Key('goal-go')));
    expect(find.byKey(const Key('goal-go')).hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the arrival heading is easy to set: 45° steps, travel direction, dragging the dial', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid(w: 4, h: 4));
    await tester.pumpAndSettle();
    await tester.tapAt(tester.getCenter(_mapFinder));
    await tester.pump(const Duration(milliseconds: 500));
    String facing() => tester.widget<Text>(find.byKey(const Key('goal-heading'))).data!;
    expect(facing(), startsWith('Faces'));

    await tester.ensureVisible(find.byKey(const Key('goal-heading-left')));
    await tester.tap(find.byKey(const Key('goal-heading-left')));
    await tester.pump();
    final afterLeft = facing();
    await tester.tap(find.byKey(const Key('goal-heading-right')));
    await tester.tap(find.byKey(const Key('goal-heading-right')));
    await tester.pump();
    expect(facing(), isNot(afterLeft));

    // Drag on the dial towards its right edge: facing 0°, i.e. along +x.
    final dial = find.byKey(const Key('goal-heading-dial'));
    final c = tester.getCenter(dial);
    final g = await tester.startGesture(c + const Offset(5, 0));
    await g.moveTo(c + const Offset(28, 0));
    await g.up();
    await tester.pump();
    expect(facing(), 'Faces 0° on arrival');
    await tester.drag(dial, const Offset(0, -1)); // a press at the top edge points up
    await tester.pump();

    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    final sent = robot.sent.where((m) => m['op'] == 'publish' && '${m['topic']}'.endsWith('goal_pose')).toList();
    expect(sent, isNotEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no map: says so after discovery and offers the topic choice; a slow map says so too', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/odom', '/scan'], 'types': ['nav_msgs/msg/Odometry', 'sensor_msgs/msg/LaserScan']};
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.pump();
    await tester.pump();
    expect(find.text('This robot has no map'), findsOneWidget);
    expect(find.byKey(const Key('choose-map-topic')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final slow = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map'], 'types': ['nav_msgs/msg/OccupancyGrid']};
    addTearDown(slow.close);
    await _open(tester, slow);
    await tester.pump();
    await tester.pump();
    expect(find.text('Waiting for the map'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('No map from /map yet'), findsOneWidget);
    slow.events.add(_grid());
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('map-waiting-title')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without rosapi type info a tapped goal goes to /goal_pose, cancellable', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    expect(find.text('Nav2 · /goal_pose'), findsOneWidget);
    expect(robot.sent, contains(predicate<Map>((m) =>
        m['op'] == 'advertise' && m['topic'] == '/goal_pose' && m['type'] == 'geometry_msgs/msg/PoseStamped')));
    await _tapAndGo(tester);
    final goals = robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/goal_pose').toList();
    expect(goals, hasLength(1));
    final msg = goals.single['msg'];
    expect(msg['header']['frame_id'], 'map');
    expect(msg['header']['stamp'], {'sec': 0, 'nanosec': 0});
    expect(msg['pose']['position']['x'], closeTo(1, 0.05));
    expect(msg['pose']['position']['y'], closeTo(1, 0.05));
    expect(find.byKey(const Key('nav-progress')), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
    expect(robot.sent.last['service'], '/navigate_to_pose/_action/cancel_goal');
    expect(find.text('Navigation canceled'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'unadvertise' && m['topic'] == '/goal_pose')));
    expect(tester.takeException(), isNull);
  });

  testWidgets('with a navigate_to_pose action server: action goal, live feedback, result', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid(w: 4, h: 4));
    await tester.pumpAndSettle();
    expect(find.text('Nav2 · navigate_to_pose'), findsOneWidget);
    await _tapAndGo(tester);
    final goal = robot.sent.singleWhere((m) => m['op'] == 'send_action_goal');
    expect(goal['action'], '/navigate_to_pose');
    expect(goal['action_type'], 'nav2_msgs/action/NavigateToPose');
    expect(goal['args']['pose']['pose']['position']['x'], closeTo(2, 0.05));
    expect(robot.sent.where((m) => m['topic'] == '/goal_pose'), isEmpty);

    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'action': '/navigate_to_pose', 'values': {
      'distance_remaining': 1.25, 'estimated_time_remaining': {'sec': 7, 'nanosec': 0}, 'number_of_recoveries': 1}});
    await tester.pump();
    expect(find.text('1.25 m left'), findsOneWidget);
    expect(find.textContaining('about 7 s'), findsOneWidget);
    expect(find.textContaining('1 recovery'), findsOneWidget);

    robot.events.add({'op': 'action_result', 'id': 'someone-else', 'status': 6, 'result': true, 'values': {}});
    await tester.pump();
    expect(find.byKey(const Key('nav-progress')), findsOneWidget, reason: 'results for other goals are ignored');
    robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 4, 'result': true, 'values': {}});
    await tester.pump();
    await tester.pump(); // the event lands after the first frame
    expect(find.text('Arrived'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('an aborted action shows failure and Retry sends again', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await _tapAndGo(tester);
    final id = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal')['id'];
    robot.events.add({'op': 'action_result', 'id': id, 'status': 6, 'result': true, 'values': {}});
    await tester.pump();
    expect(find.text('Navigation failed'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-retry')));
    await tester.pump();
    expect(robot.sent.where((m) => m['op'] == 'send_action_goal'), hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after a failed trip, "Clear obstacle memory" clears the costmaps (only when the robot has them)',
      (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']}
      ..serviceResponses['/rosapi/services'] = {'services': [
        '/local_costmap/clear_entirely_local_costmap', '/global_costmap/clear_entirely_global_costmap']}
      ..serviceResponses['/local_costmap/clear_entirely_local_costmap'] = {}
      ..serviceResponses['/global_costmap/clear_entirely_global_costmap'] = {};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await _tapAndGo(tester);
    final id = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal')['id'];
    robot.events.add({'op': 'action_result', 'id': id, 'status': 6, 'result': true, 'values': {}});
    await tester.pump();
    await tester.tap(find.byKey(const Key('nav-clear-costmaps')));
    await tester.pumpAndSettle();
    expect(robot.calls.map((c) => c.$1), containsAll(['/local_costmap/clear_entirely_local_costmap',
      '/global_costmap/clear_entirely_global_costmap']));
    expect(find.textContaining('plans again'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no costmap services, no clear button', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await _tapAndGo(tester);
    final id = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal')['id'];
    robot.events.add({'op': 'action_result', 'id': id, 'status': 6, 'result': true, 'values': {}});
    await tester.pump();
    expect(find.text('Navigation failed'), findsOneWidget);
    expect(find.byKey(const Key('nav-clear-costmaps')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Layers > Local costmap subscribes only then, and draws what arrives over the map', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/map', '/odom', '/local_costmap/costmap', '/global_costmap/costmap'],
        'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/OccupancyGrid',
          'nav_msgs/msg/OccupancyGrid']};
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.pump(const Duration(milliseconds: 50));
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    expect(robot.sent.where((m) => m['op'] == 'subscribe' && '${m['topic']}'.contains('costmap')), isEmpty,
        reason: 'a costmap is a big message every second: not asked for until the layer is on');

    await tester.tap(find.byKey(const Key('map-layers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layer-costmap-local')));
    await tester.pumpAndSettle();
    final sub = robot.sent.lastWhere((m) => m['op'] == 'subscribe' && m['topic'] == '/local_costmap/costmap');
    expect(sub['throttle_rate'], 1000);
    expect(robot.sent.where((m) => m['op'] == 'subscribe' && m['topic'] == '/global_costmap/costmap'), isEmpty);

    robot.events.add({'op': 'publish', 'topic': '/local_costmap/costmap', 'msg': {
      'header': {'frame_id': 'map'},
      'info': {'width': 2, 'height': 2, 'resolution': 0.5, 'origin': {
        'position': {'x': 0.0, 'y': 0.0, 'z': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
      'data': [100, 50, 0, 0]}});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    await tester.pump();
    final painters = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter).whereType<MapPainter>();
    expect(painters.single.costmaps, hasLength(1));

    await tester.tap(find.byKey(const Key('map-layers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layer-costmap-local')));
    await tester.pumpAndSettle();
    expect(robot.sent.last, containsPair('op', 'unsubscribe'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Patrol: tick two places, start, follow the feedback, stop; offered only with FollowWaypoints',
      (tester) async {
    SharedPreferences.setMockInitialValues({'places:robot:9090': jsonEncode([
      {'name': 'door', 'x': 0.5, 'y': 0.5, 'yaw': 0.0, 'frame': 'map'},
      {'name': 'desk', 'x': 1.5, 'y': 1.0, 'yaw': 1.0, 'frame': 'map'},
      {'name': 'kitchen', 'x': 1.0, 'y': 1.5, 'yaw': 2.0, 'frame': 'map'},
    ])});
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose', '/follow_waypoints']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('patrol-open')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('patrol-start'))).onPressed, isNull,
        reason: 'two places at least');
    await tester.tap(find.byKey(const Key('patrol-pick-kitchen')));
    await tester.tap(find.byKey(const Key('patrol-pick-door')));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget, reason: 'numbered in the order ticked');
    await tester.tap(find.byKey(const Key('patrol-start')));
    await tester.pumpAndSettle();

    final goal = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
    expect(goal['action'], '/follow_waypoints');
    final poses = goal['args']['poses'] as List;
    expect(poses.map((p) => p['pose']['position']['x']), [1.0, 0.5], reason: 'kitchen, then door');
    expect(find.text('Going to kitchen (1 of 2)'), findsOneWidget);
    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {'current_waypoint': 1}});
    await tester.pump();
    await tester.pump();
    expect(find.text('Going to door (2 of 2)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('patrol-stop')));
    await tester.pump();
    expect(robot.sent.where((m) => m['op'] == 'cancel_action_goal'), isNotEmpty);
    expect(find.text('Patrol stopped'), findsOneWidget);
    await tester.tap(find.byKey(const Key('patrol-dismiss')));
    await tester.pump();
    expect(find.byKey(const Key('patrol-result')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Dock: ask for the dock name once, dock, follow the stages, and undock', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': [
        '/navigate_to_pose', '/dock_robot', '/undock_robot']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('dock-open')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('dock-name')), 'home_dock');
    await tester.tap(find.byKey(const Key('dock-go')));
    // Docking shows an indeterminate bar that never settles: step the dialog's close by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final goal = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
    expect(goal['action'], '/dock_robot');
    expect(goal['args']['dock_id'], 'home_dock');
    expect(find.text('Starting…'), findsOneWidget);
    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {'state': 2, 'num_retries': 1}});
    await tester.pump();
    await tester.pump();
    expect(find.text('Looking for the dock'), findsOneWidget);
    expect(find.text('1 retry'), findsOneWidget);
    robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 6, 'result': true,
      'values': {'success': false, 'error_code': 904, 'num_retries': 1, 'error_msg': ''}});
    await tester.pump();
    await tester.pump();
    expect(find.text('Docking failed'), findsOneWidget);
    expect(find.text('The robot could not see the dock.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('dock-dismiss')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('dock-open')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('dock-name'))).controller!.text, 'home_dock',
        reason: 'remembered');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('undock-open')));
    await tester.pump();
    final undock = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
    expect(undock['action'], '/undock_robot');
    robot.events.add({'op': 'action_result', 'id': undock['id'], 'status': 4, 'result': true,
      'values': {'success': true, 'error_code': 0, 'error_msg': ''}});
    await tester.pump();
    await tester.pump();
    expect(find.text('Left the charger'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no FollowWaypoints, no Patrol button', (tester) async {
    SharedPreferences.setMockInitialValues({'places:robot:9090': jsonEncode([
      {'name': 'door', 'x': 0.5, 'y': 0.5, 'yaw': 0.0, 'frame': 'map'},
      {'name': 'desk', 'x': 1.5, 'y': 1.0, 'yaw': 1.0, 'frame': 'map'},
    ])});
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('patrol-open')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('press-and-drag sets the goal heading', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid(w: 20, h: 20, res: 0.1));
    await tester.pumpAndSettle();
    final c = tester.getCenter(_mapFinder);
    final g = await tester.startGesture(c);
    await tester.pump(const Duration(milliseconds: 600)); // long press
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(0, -12)); // drag up = north (+y) on an unrotated map
      await tester.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await tester.pump();
    final goal = _painter(tester).goal!;
    expect(goal.yaw, closeTo(math.pi / 2, 0.05));
    await tester.tap(find.byKey(const Key('goal-go')));
    await tester.pump();
    final q = robot.sent.lastWhere((m) => m['topic'] == '/goal_pose')['msg']['pose']['orientation'];
    expect(yawOf(q as Map), closeTo(math.pi / 2, 0.05));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('TF is unthrottled; robot pose comes from the TF chain and odometry', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    final tfSub = robot.sent.singleWhere((m) => m['op'] == 'subscribe' && m['topic'] == '/tf');
    expect(tfSub['throttle_rate'] ?? 0, 0, reason: 'a throttle drops the slower map->odom transforms');
    robot.events
      ..add(_grid(w: 4, h: 4))
      ..add({'op': 'publish', 'topic': '/odom', 'msg': {
        'header': {'frame_id': 'odom'}, 'pose': {'pose': {'position': {'x': 1.0, 'y': 0.0}}}}});
    await tester.pump(const Duration(milliseconds: 60)); // map redraws are capped at ~20 fps
    expect(_painter(tester).showRobot, isFalse);
    robot.events.add({'op': 'publish', 'topic': '/tf', 'msg': {'transforms': [_tf('map', 'odom', 2, 1)]}});
    await tester.pump(const Duration(milliseconds: 60)); // map redraws are capped at ~20 fps
    expect(_painter(tester).robot!.x, closeTo(3, 1e-9));
    expect(_painter(tester).robot!.y, closeTo(1, 1e-9));
    // With base_footprint in TF (and odom naming it), the full chain is used, including heading.
    robot.events
      ..add({'op': 'publish', 'topic': '/odom', 'msg': {'header': {'frame_id': 'odom'}, 'child_frame_id': 'base_footprint',
        'pose': {'pose': {'position': {'x': 1.0, 'y': 0.0}}}}})
      ..add({'op': 'publish', 'topic': '/tf', 'msg': {'transforms': [_tf('odom', 'base_footprint', 0.5, 0, math.pi / 2)]}});
    await tester.pump(const Duration(milliseconds: 60)); // map redraws are capped at ~20 fps
    expect(_painter(tester).robot!.x, closeTo(2.5, 1e-9));
    expect(_painter(tester).robot!.yaw, closeTo(math.pi / 2, 1e-9));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('LiDAR and planned path are drawn in the map frame', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/scan', '/plan', '/local_plan'],
      'types': ['nav_msgs/msg/OccupancyGrid', 'sensor_msgs/msg/LaserScan', 'nav_msgs/msg/Path', 'nav_msgs/msg/Path'],
    };
    addTearDown(robot.close);
    await _open(tester, robot);
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/scan')));
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/plan')));
    expect(robot.sent.where((m) => m['topic'] == '/local_plan'), isEmpty);
    robot.events
      ..add(_grid(w: 10, h: 10))
      ..add({'op': 'publish', 'topic': '/tf', 'msg': {'transforms': [_tf('map', 'odom', 1, 1), _tf('odom', 'laser', 1, 0)]}})
      ..add({'op': 'publish', 'topic': '/scan', 'msg': {'header': {'frame_id': 'laser'},
        'angle_min': 0.0, 'angle_increment': math.pi / 2, 'range_min': 0.1, 'range_max': 10.0,
        'ranges': [2.0, null, 0.05, 3.0]}})
      ..add({'op': 'publish', 'topic': '/plan', 'msg': {'header': {'frame_id': 'map'}, 'poses': [
        {'pose': {'position': {'x': 1.0, 'y': 1.0}}}, {'pose': {'position': {'x': 4.0, 'y': 5.0}}}]}});
    await tester.pumpAndSettle();
    final scan = _painter(tester).scan;
    expect(scan, hasLength(2), reason: 'null (inf) and below range_min are dropped');
    expect(scan.first.x, closeTo(4, 1e-9)); // laser at (2,1) + 2 m along +x
    expect(scan.last.y, closeTo(-2, 1e-9)); // 3 m along -y
    expect(_painter(tester).path, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Set pose previews the position, lets the heading be turned, and publishes on confirm', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set pose'));
    await tester.pump();
    await tester.tapAt(tester.getCenter(_mapFinder));
    await tester.pump(const Duration(milliseconds: 500));
    expect(robot.sent.where((m) => m['topic'] == '/initialpose' && m['op'] == 'publish'), isEmpty,
        reason: 'nothing is sent before the person confirms');
    await tester.ensureVisible(find.byKey(const Key('pose-heading-left')));
    await tester.tap(find.byKey(const Key('pose-heading-left'))); // 0° -> 45°
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('pose-heading'))).data, 'Faces 45°');
    await tester.ensureVisible(find.byKey(const Key('pose-confirm')));
    await tester.tap(find.byKey(const Key('pose-confirm')));
    await tester.pump();
    final pose = robot.sent.singleWhere((m) => m['op'] == 'publish' && m['topic'] == '/initialpose');
    expect(pose['msg']['header']['frame_id'], 'map');
    expect(pose['msg']['pose']['pose']['position']['x'], closeTo(1, 0.05));
    expect((pose['msg']['pose']['covariance'] as List).length, 36);
    expect(pose['msg']['pose']['pose']['orientation']['z'], closeTo(math.sin(math.pi / 8), 0.01), reason: '45°');
    expect(robot.sent.where((m) => m['topic'] == '/goal_pose' && m['op'] == 'publish'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Find automatically matches the laser against the map and previews the spot to confirm', (tester) async {
    // A 4 m x 3 m L-shaped room (0.05 m cells), so only one spot fits.
    const w = 80, h = 60, res = 0.05;
    final cells = List.filled(w * h, 0);
    for (var r = 0; r < h; r++) {
      for (var c = 0; c < w; c++) {
        if (r == 0 || c == 0 || r == h - 1 || c == w - 1 || (r >= 35 && c >= 50)) cells[r * w + c] = 100;
      }
    }
    const truth = Pose2D(1.2, 0.9, 0.7);
    final ranges = <double?>[];
    for (var i = 0; i < 180; i++) {
      final a = truth.yaw + i * 2 * math.pi / 180;
      double? hit;
      for (var d = 0.05; d < 10; d += res / 4) {
        final c = ((truth.x + d * math.cos(a)) / res).floor(), r = ((truth.y + d * math.sin(a)) / res).floor();
        if (c < 0 || r < 0 || c >= w || r >= h) break;
        if (cells[r * w + c] == 100) { hit = d; break; }
      }
      ranges.add(hit);
    }
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/scan'], 'types': ['nav_msgs/msg/OccupancyGrid', 'sensor_msgs/msg/LaserScan']};
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events
      ..add(_grid(w: w, h: h, res: res, data: cells))
      // The robot wrongly believes it is at (2.5, 0.5) facing 180°.
      ..add({'op': 'publish', 'topic': '/tf', 'msg': {'transforms': [
        _tf('map', 'odom', 0, 0), _tf('odom', 'base_footprint', 2.5, 0.5, math.pi)]}})
      ..add({'op': 'publish', 'topic': '/scan', 'msg': {'header': {'frame_id': 'base_footprint'},
        'angle_min': 0.0, 'angle_increment': 2 * math.pi / 180, 'range_min': 0.04, 'range_max': 10.0,
        'ranges': ranges}});
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set pose'));
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('pose-match'))).data, contains('does not fit'),
        reason: 'the believed pose is wrong');

    await tester.tap(find.byKey(const Key('pose-auto')));
    await tester.runAsync(() async {
      for (var i = 0; i < 100 && _painter(tester).pendingPose?.x == 2.5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
    await tester.pump();
    final found = _painter(tester).pendingPose!;
    expect(found.distanceTo(truth), lessThan(0.1));
    expect(_painter(tester).previewScan, isNotEmpty, reason: 'the laser is drawn at the found spot');
    expect(tester.widget<Text>(find.byKey(const Key('pose-note'))).data, startsWith('Found it'));
    expect(tester.widget<Text>(find.byKey(const Key('pose-match'))).data, contains('fits the walls'));
    expect(robot.sent.where((m) => m['topic'] == '/initialpose' && m['op'] == 'publish'), isEmpty,
        reason: 'nothing is sent before the person confirms');

    await tester.ensureVisible(find.byKey(const Key('pose-confirm')));
    await tester.tap(find.byKey(const Key('pose-confirm')));
    await tester.pump();
    final sent = robot.sent.singleWhere((m) => m['op'] == 'publish' && m['topic'] == '/initialpose');
    expect(sent['msg']['pose']['pose']['position']['x'], closeTo(truth.x, 0.1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a ROS 1 robot (pkg/Type names) gets a move_base goal and cancel', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/move_base/goal'], 'types': ['nav_msgs/OccupancyGrid', 'move_base_msgs/MoveBaseActionGoal'],
    };
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    expect(find.text('ROS 1 · move_base'), findsOneWidget);
    await _tapAndGo(tester);
    final goal = robot.sent.singleWhere((m) => m['op'] == 'publish' && m['topic'] == '/move_base/goal');
    final target = goal['msg']['goal']['target_pose'];
    expect(target['header']['frame_id'], 'map');
    expect(target['pose']['position']['x'], closeTo(1, 0.05));
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
    expect(robot.sent.last['topic'], '/move_base/cancel');
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('discovers namespaced map, odometry, initial pose, and Nav2 action topics', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/robot1/map', '/robot1/odom', '/robot1/tf', '/robot1/tf_static',
          '/robot1/scan', '/robot1/plan', '/robot1/goal_pose', '/robot1/initialpose'],
        'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry',
          'tf2_msgs/msg/TFMessage', 'tf2_msgs/msg/TFMessage', 'sensor_msgs/msg/LaserScan',
          'nav_msgs/msg/Path', 'geometry_msgs/msg/PoseStamped',
          'geometry_msgs/msg/PoseWithCovarianceStamped'],
      }
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/robot1/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/robot1/map')));
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/robot1/odom')));
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'advertise' && m['topic'] == '/robot1/initialpose')));
    expect(find.text('Nav2 · /robot1/navigate_to_pose'), findsOneWidget);

    final grid = _grid(w: 4, h: 4)..['topic'] = '/robot1/map';
    robot.events.add(grid);
    await tester.pumpAndSettle();
    await _tapAndGo(tester);
    final goal = robot.sent.singleWhere((m) => m['op'] == 'send_action_goal');
    expect(goal['action'], '/robot1/navigate_to_pose');
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
    expect(robot.sent.lastWhere((m) => m['op'] == 'cancel_action_goal')['action'], '/robot1/navigate_to_pose');
    expect(robot.sent.last, containsPair('op', 'unsubscribe'), reason: 'the behavior tree log ends with the goal');
  });

  testWidgets('while navigating, a Nav2 recovery from its behavior tree is shown under the distance', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/map', '/odom'], 'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry']}
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/navigate_to_pose']};
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    robot.events.add(_grid(w: 4, h: 4)..['topic'] = '/map');
    await tester.pumpAndSettle();
    await _tapAndGo(tester);
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/behavior_tree_log')));
    final goal = robot.sent.singleWhere((m) => m['op'] == 'send_action_goal');
    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {'distance_remaining': 1.5}});
    robot.events.add({'op': 'publish', 'topic': '/behavior_tree_log', 'msg': {'event_log': [
      {'node_name': 'Spin', 'previous_status': 'IDLE', 'current_status': 'RUNNING'}]}});
    await tester.pump();
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('nav-activity'))).data, 'Recovering: turning in place');
    robot.events.add({'op': 'publish', 'topic': '/behavior_tree_log', 'msg': {'event_log': [
      {'node_name': 'Spin', 'previous_status': 'RUNNING', 'current_status': 'SUCCESS'},
      {'node_name': 'ComputePathToPose', 'previous_status': 'IDLE', 'current_status': 'RUNNING'},
      {'node_name': 'ComputePathToPose', 'previous_status': 'RUNNING', 'current_status': 'SUCCESS'}]}});
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('nav-activity')), findsNothing, reason: 'back on its way: nothing extra to say');
    await tester.tap(find.byKey(const Key('nav-cancel')));
    await tester.pump();
  });

  testWidgets('saved topic overrides are used instead of discovery', (tester) async {
    SharedPreferences.setMockInitialValues({'map_topics:robot:9090': '{"odom": "/wheel_state", "map": "/slam/grid"}'});
    final robot = FakeConnection();
    addTearDown(robot.close);
    await _open(tester, robot);
    await tester.pump(); // no map yet: the waiting spinner never settles
    final subs = robot.sent.where((m) => m['op'] == 'subscribe').map((m) => m['topic']).toList();
    expect(subs, containsAll(['/wheel_state', '/slam/grid', '/tf']));
    expect(subs, isNot(contains('/odom')));
    robot.events.add({..._grid(), 'topic': '/slam/grid'});
    await tester.pumpAndSettle();
    expect(_mapFinder, findsOneWidget, reason: 'the grid arrives on the overridden topic');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the topic sheet changes odometry live and saves it per robot', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/map', '/odom', '/wheel_state'],
      'types': ['nav_msgs/msg/OccupancyGrid', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/Odometry'],
    };
    addTearDown(robot.close);
    await _open(tester, robot);
    robot.events.add(_grid());
    await tester.pumpAndSettle();
    expect(robot.sent.where((m) => m['op'] == 'subscribe').map((m) => m['topic']), contains('/odom'));

    await tester.tap(find.byKey(const Key('map-topics')));
    await tester.pumpAndSettle();
    expect(find.text('Auto: /odom'), findsOneWidget);
    await tester.tap(find.byKey(const Key('map-topic-pick-odom')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/wheel_state').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-topics-save')));
    await tester.pumpAndSettle();

    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'unsubscribe' && m['topic'] == '/odom')));
    expect(robot.sent.last, isNot(predicate<Map>((m) => m['topic'] == '/map' && m['op'] == 'unsubscribe')));
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/wheel_state')));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('map_topics:robot:9090'), contains('/wheel_state'));
    robot.events.add({'op': 'publish', 'topic': '/wheel_state', 'msg': {'header': {'frame_id': 'map'},
      'pose': {'pose': {'position': {'x': 1.0, 'y': 1.0}}}}});
    await tester.pump();
    await tester.pump(); // the event lands after the first frame
    expect(_painter(tester).robot, isNotNull, reason: 'odometry now comes from /wheel_state');
    await tester.pumpWidget(const SizedBox());
  });

  test('TF tree composes chains and normalises angles', () {
    final tree = TfTree()
      ..add(_tf('/map', 'odom', 1, 0, math.pi / 2))
      ..add(_tf('odom', 'base', 2, 0, math.pi));
    final p = tree.lookup('map', 'base')!;
    expect(p.x, closeTo(1, 1e-9));
    expect(p.y, closeTo(2, 1e-9));
    expect(p.yaw.abs(), closeTo(math.pi / 2, 1e-9));
    expect(tree.lookup('map', 'nowhere'), isNull);
    expect(tree.add(_tf('map', 'odom', 1, 0, math.pi / 2)), isFalse, reason: 'unchanged');
  });
}
