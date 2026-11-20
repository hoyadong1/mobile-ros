import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/validator.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

class Scripted extends AgentBackend {
  Scripted(this.calls);
  final List<SkillCall> calls;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls);
}

Map<String, dynamic> grid() => {
  'op': 'publish', 'topic': '/map', 'msg': {
    'header': {'frame_id': 'map'},
    'info': {'width': 4, 'height': 4, 'resolution': 1.0, 'origin': {
      'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
    'data': List.filled(16, 0),
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('places are saved per robot, replaced by name, found ignoring case and spaces', () async {
    final book = PlaceBook('robot:9090');
    await book.load();
    await book.save(const Place('주방', 1, 2, yaw: 0.5));
    await book.save(const Place('Dock', 3, 4));
    await book.save(const Place(' dock ', 5, 6)); // same name: replaces
    expect(book.places.map((p) => p.name), ['주방', 'dock']);
    expect(book.find('DOCK')!.x, 5);

    final again = PlaceBook('robot:9090');
    await again.load();
    expect(again.find('주방')!.yaw, 0.5, reason: 'stored');
    final other = PlaceBook('other:9090');
    await other.load();
    expect(other.places, isEmpty, reason: 'per robot');
    await again.remove('주방');
    expect(again.places.map((p) => p.name), ['dock']);
  });

  test('floors: a named map keeps its places; another floor does not offer them, nor the AI', () async {
    final first = PlaceBook.mapKey(frame: 'map', width: 400, height: 300, resolution: 0.05, originX: -10, originY: -7.5);
    final second = PlaceBook.mapKey(frame: 'map', width: 520, height: 300, resolution: 0.05, originX: -13, originY: -7.5);
    final book = PlaceBook('tower:9090');
    await book.load();
    await book.save(const Place('Lobby', 1, 1)); // saved before any floor was named: any map
    book.observeMap(first);
    expect(book.floor, isNull);
    await book.save(const Place('Loose', 2, 2));
    expect(book.find('Loose')!.floor, isNull, reason: 'an unnamed map does not tie places to it');
    await book.nameFloor(' 1F ');
    expect(book.floor, '1F');
    await book.save(const Place('Kitchen', 3, 4));
    expect(book.find('Kitchen')!.floor, first);
    book.observeMap(second);
    expect(book.floor, isNull);
    expect(book.usable.map((p) => p.name), ['Lobby', 'Loose'], reason: 'the 1F kitchen is not on this map');
    expect(book.elsewhere, 1);
    await book.nameFloor('2F');
    await book.save(const Place('Office', 3, 4));
    expect(book.usable.map((p) => p.name), ['Lobby', 'Loose', 'Office']);
    // The AI is offered only this floor's places.
    final nav = NavigationController(RosClient(FakeConnection()))
      ..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
    final drive = DriveController(RosClient(FakeConnection()))
      ..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    addTearDown(() { nav.dispose(); drive.dispose(); });
    final m = AgentManifest.build(profile: drive.profile, nav: nav, places: book.usable);
    expect(validateCall(const SkillCall('go_to_place', {'name': 'Kitchen'}), m).ok, isFalse,
        reason: 'same coordinates on another floor are somewhere else');
    // Remembered after a restart; back on 1F the kitchen is there again.
    final again = PlaceBook('tower:9090');
    await again.load();
    again.observeMap(first);
    expect(again.floor, '1F');
    expect(again.usable.map((p) => p.name), ['Lobby', 'Loose', 'Kitchen']);
    // While a map is being made the floor is unknown: only places for any map.
    again.observeMap(null);
    expect(again.usable.map((p) => p.name), ['Lobby', 'Loose']);
  });

  group('go_to_place', () {
    late FakeConnection robot;
    late NavigationController nav;
    late DriveController drive;
    late PlaceBook places;

    setUp(() async {
      robot = FakeConnection();
      final ros = RosClient(robot);
      nav = NavigationController(ros)..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
      drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
      places = PlaceBook('robot:9090');
      await places.load();
      await places.save(const Place('주방', 1.5, -2, yaw: 1.0));
    });
    tearDown(() {
      nav.dispose();
      drive.dispose();
    });

    test('is offered with saved names when the robot can navigate', () {
      final m = AgentManifest.build(profile: drive.profile, nav: nav, places: places.places);
      final schema = m.skill('go_to_place')!.toToolJson()['input_schema'] as Map;
      expect(((schema['properties'] as Map)['name'] as Map)['enum'], ['주방']);
      expect(m.describe(), contains('Saved places on the map: 주방.'));
      expect(AgentManifest.build(profile: drive.profile, nav: nav).skill('go_to_place'), isNull,
          reason: 'no places saved');
      expect(validateCall(const SkillCall('go_to_place', {'name': '거실'}), m).ok, isFalse,
          reason: 'only saved names');
    });

    test('drives to the place through Nav2 and reports arrival', () async {
      final agent = RobotAgent(drive: drive, nav: nav, places: places,
          backend: Scripted([const SkillCall('go_to_place', {'name': '주방'})]));
      final running = agent.handle('주방으로 가');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final goal = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
      expect(goal['args']['pose']['pose']['position'], {'x': 1.5, 'y': -2.0, 'z': 0.0});
      robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 4, 'result': true});
      final run = await running;
      expect(run.ok, isTrue);
      expect(run.results.single.message, 'Arrived at 주방.');
    });
  });

  testWidgets('a previewed goal can be saved as a place, listed, and picked again', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection();
    addTearDown(robot.close);
    final book = PlaceBook('robot:9090');
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, places: book)));
    await tester.pump();
    robot.events.add(grid());
    await tester.pumpAndSettle();

    final map = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is MapPainter);
    await tester.tapAt(tester.getCenter(map));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('goal-save-place')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('place-name')), '충전기');
    await tester.tap(find.byKey(const Key('place-save')));
    await tester.pumpAndSettle();
    expect(book.find('충전기'), isNotNull);
    expect(tester.widget<CustomPaint>(map).painter, isA<MapPainter>()
        .having((p) => p.places.single.$1, 'pin', '충전기'));

    await tester.tap(find.byKey(const Key('goal-clear')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('map-places')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('place-충전기')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('goal-go')), findsOneWidget, reason: 'the place is previewed as the goal');
    await tester.pumpWidget(const SizedBox());
  });

  /// A [w] x 4 map (each floor of the test building has its own width).
  Map<String, dynamic> floorGrid(int w) => {
    'op': 'publish', 'topic': '/map', 'msg': {
      'header': {'frame_id': 'map'},
      'info': {'width': w, 'height': 4, 'resolution': 1.0, 'origin': {
        'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
      'data': List.filled(w * 4, 0)}};

  Future<void> nameFloor(WidgetTester tester, String name, String file) async {
    await tester.tap(find.byKey(const Key('map-places')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('floor-here')), matching: find.byType(TextButton)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('floor-name-field')), name);
    await tester.enterText(find.byKey(const Key('floor-map-field')), file);
    await tester.tap(find.text('Save').last);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(450, 20)); // close the places sheet
    await tester.pumpAndSettle();
  }

  testWidgets('the map shown can be named as a floor; its name shows under the title', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection();
    addTearDown(robot.close);
    final book = PlaceBook('robot:9090');
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, places: book)));
    await tester.pump();
    robot.events.add(grid());
    await tester.pumpAndSettle();
    expect(book.currentMap, isNotNull, reason: 'the map is recognised');
    await nameFloor(tester, 'B1', '/maps/b1.yaml');
    expect(book.floor, 'B1');
    expect(book.floors[book.currentMap]!.mapFile, '/maps/b1.yaml');
    expect(tester.widget<Text>(find.byKey(const Key('nav-target'))).data, startsWith('B1 · '));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('switching floors loads that floor map on the robot, then asks where the robot is', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection()..serviceResponses['/rosapi/services'] = {
      'services': ['/map_server/load_map', '/rosapi/services']}
      ..serviceResponses['/map_server/load_map'] = {'result': 0};
    addTearDown(robot.close);
    final book = PlaceBook('robot:9090');
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, places: book)));
    await tester.pump();
    robot.events.add(floorGrid(4));
    await tester.pumpAndSettle();
    await nameFloor(tester, '1F', '/maps/1f.yaml');
    await book.save(const Place('Lift 1F', 1, 2, yaw: 0.5));
    // The robot is taken to the second floor and its map loaded there by hand: name that floor too.
    robot.events.add(floorGrid(6));
    await tester.pumpAndSettle();
    expect(book.floor, isNull);
    await nameFloor(tester, '2F', '/maps/2f.yaml');
    expect(book.usable.map((p) => p.name), isEmpty, reason: 'the 1F lift is not on this floor');

    await tester.tap(find.byKey(const Key('map-places')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-switch-1F')));
    await tester.pump();
    expect(robot.calls.where((c) => c.$1 == '/map_server/load_map').single.$2, {'map_url': '/maps/1f.yaml'});
    robot.events.add(floorGrid(4)); // the map server publishes the loaded map
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(book.floor, '1F');
    expect(robot.sent.where((m) => m['op'] == 'publish' && '${m['topic']}'.contains('initialpose')), isEmpty,
        reason: 'the position is not guessed');
    await tester.tap(find.byKey(const Key('where-Lift 1F')));
    await tester.pumpAndSettle();
    final pose = robot.sent.lastWhere((m) => m['op'] == 'publish' && '${m['topic']}'.contains('initialpose'));
    expect(pose['msg']['pose']['pose']['position']['x'], 1.0);
    expect(robot.sent.where((m) => m['op'] == 'send_action_goal' || '${m['topic']}'.contains('cmd_vel')), isEmpty,
        reason: 'switching floors never moves the robot');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a map the robot cannot load is said in words', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection()..serviceResponses['/rosapi/services'] = {'services': ['/map_server/load_map']}
      ..serviceResponses['/map_server/load_map'] = {'result': 1};
    addTearDown(robot.close);
    final book = PlaceBook('robot:9090');
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, places: book)));
    await tester.pump();
    robot.events.add(floorGrid(4));
    await tester.pumpAndSettle();
    await nameFloor(tester, '1F', '/maps/1f.yaml');
    robot.events.add(floorGrid(6));
    await tester.pumpAndSettle();
    await nameFloor(tester, '2F', '/maps/2f.yaml');
    await tester.tap(find.byKey(const Key('map-places')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-switch-1F')));
    await tester.pumpAndSettle();
    expect(find.textContaining('no map file "/maps/1f.yaml"'), findsOneWidget);
    expect(find.byKey(const Key('where-on-map')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('after a floor change the position can be searched; nothing is set before the person checks it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {'topics': ['/map', '/scan'],
        'types': ['nav_msgs/msg/OccupancyGrid', 'sensor_msgs/msg/LaserScan']}
      ..serviceResponses['/rosapi/services'] = {'services': ['/map_server/load_map']}
      ..serviceResponses['/map_server/load_map'] = {'result': 0};
    addTearDown(robot.close);
    final book = PlaceBook('robot:9090');
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, places: book)));
    await tester.pump();
    robot.events.add(floorGrid(4));
    await tester.pumpAndSettle();
    await nameFloor(tester, '1F', '/maps/1f.yaml');
    robot.events.add(floorGrid(6));
    await tester.pumpAndSettle();
    await nameFloor(tester, '2F', '/maps/2f.yaml');
    await tester.tap(find.byKey(const Key('map-places')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('floor-switch-1F')));
    await tester.pump();
    robot.events.add(floorGrid(4));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('where-find')));
    await tester.pumpAndSettle();
    expect(find.text('Set robot position'), findsOneWidget, reason: 'the search result is shown to check');
    expect(robot.sent.where((m) => m['op'] == 'publish' && '${m['topic']}'.contains('initialpose')), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
