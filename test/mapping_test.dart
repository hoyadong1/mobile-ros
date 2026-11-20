import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/mapping.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import 'support/fake_ros_connection.dart';

Map<String, dynamic> _grid(int w, int h, List<int> data) => {
  'op': 'publish', 'topic': '/map', 'msg': {
    'header': {'frame_id': 'map'},
    'info': {'width': w, 'height': h, 'resolution': 0.5, 'origin': {
      'position': {'x': -1.0, 'y': -2.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
    'data': data,
  },
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('mapping helpers', () {
    test('finds the mapper and the best way to save', () async {
      final robot = FakeConnection()..serviceResponses['/rosapi/services'] = {'services': [
        '/slam_toolbox/save_map', '/map_saver/save_map', '/map_saver/get_state']};
      final s = await detectMapping(robot, ['/slam_toolbox', '/amcl_x', '/bt_navigator']);
      expect(s.mapper, 'slam_toolbox');
      expect(s.saver, MapSaver.nav2, reason: 'Nav2 map_saver preferred (standard .pgm/.yaml)');
      expect(s.saveService, '/map_saver/save_map');
      final none = await detectMapping(FakeConnection(), ['/map_server', '/amcl']);
      expect(none.mapping, isFalse);
      expect(none.canSaveOnRobot, isFalse);
      final carto = await detectMapping(FakeConnection(), ['/cartographer_node']);
      expect(carto.mapper, 'Cartographer');
    });

    test('saves on the robot with each saver\'s own request', () async {
      final robot = FakeConnection()..serviceResponses['/map_saver/save_map'] = {'result': true};
      final ros = RosClient(robot);
      await saveMapOnRobot(ros, const MappingSetup(mapper: 'x', saver: MapSaver.nav2, saveService: '/map_saver/save_map'),
          'kitchen');
      expect(robot.calls.last.$2['map_url'], 'kitchen');
      expect(robot.calls.last.$2['map_topic'], 'map');
      robot.serviceResponses['/slam_toolbox/save_map'] = {'result': 0};
      await saveMapOnRobot(ros, const MappingSetup(mapper: 'x', saver: MapSaver.slamToolbox,
          saveService: '/slam_toolbox/save_map'), 'kitchen');
      expect(robot.calls.last.$2, {'name': {'data': 'kitchen'}});
      robot.serviceResponses['/map_saver/save_map'] = {'result': false};
      expect(() => saveMapOnRobot(ros, const MappingSetup(mapper: 'x', saver: MapSaver.nav2,
          saveService: '/map_saver/save_map'), 'kitchen'), throwsStateError);
    });

    test('file names, area, and map_server files', () {
      expect(mapFileName(' My office / 2nd floor '), 'My_office_2nd_floor');
      expect(mapFileName('..'), 'map');
      expect(defaultMapName(DateTime(2026, 11, 14, 9, 5)), 'map_20261114_0905');
      // 3 x 2: bottom row free, wall, unknown; top row free, free, 50 (uncertain)
      final cells = [0, 100, -1, 0, 0, 50];
      expect(mappedArea(cells, 0.5), 0.75);
      final f = mapFiles('m', cells, 3, 2, 0.5, const Pose2D(-1, -2, 0));
      final header = 'P5\n# Mobile ROS\n3 2\n255\n'.codeUnits;
      expect(f.pgm.sublist(0, header.length), header);
      expect(f.pgm.sublist(header.length), [254, 254, 205, 254, 0, 205], reason: 'top image row is the top of the map');
      expect(f.yaml, contains('image: m.pgm'));
      expect(f.yaml, contains('resolution: 0.5'));
      expect(f.yaml, contains('origin: [-1.0, -2.0, 0.0]'));
    });
  });

  testWidgets('one map screen: opens in Make a map when SLAM runs, switches to Goal and back, the stick lets go',
      (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/nodes'] = {'nodes': ['/slam_toolbox']}
      ..serviceResponses['/rosapi/services'] = {'services': ['/slam_toolbox/save_map']};
    addTearDown(robot.close);
    final drive = DriveController(RosClient(robot))
      ..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    addTearDown(drive.dispose);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Opened as "Map & navigation": the robot is mapping, so the page starts there.
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, drive: drive)));
    await tester.pump();
    robot.events.add(_grid(4, 4, [for (var i = 0; i < 16; i++) i < 8 ? 0 : -1]));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    SegmentedButton<String> toggle() => tester.widget(find.byKey(const Key('map-tool')));
    expect(toggle().selected, {'map'});
    expect(find.byKey(const Key('mapping-stick')), findsOneWidget);

    await tester.tap(find.text('Goal'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(toggle().selected, {'goal'});
    expect(find.text('Map & navigation'), findsOneWidget);
    expect(find.byKey(const Key('mapping-stick')), findsNothing);
    expect(drive.manualInput().linearX, 0, reason: 'the stick no longer drives');

    await tester.tap(find.text('Make map'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(toggle().selected, {'map'});
    expect(find.byKey(const Key('mapping-stick')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a stick there is no Make map choice, and a robot without a map is not pushed into it',
      (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/nodes'] = {'nodes': ['/slam_toolbox']};
    addTearDown(robot.close);
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Make map'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Make a map: no SLAM and no map explains how to start mapping', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/nodes'] = {'nodes': ['/rosbridge_websocket']};
    addTearDown(robot.close);
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, mapping: true)));
    await tester.pump();
    await tester.pump();
    expect(find.text('Start mapping on the robot'), findsOneWidget);
    expect(find.textContaining('slam_toolbox online_async_launch.py'), findsOneWidget);
    expect(find.byKey(const Key('mapping-recheck')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Make a map: shows the area, drives with the stick, saves on the robot and the phone', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/nodes'] = {'nodes': ['/slam_toolbox', '/map_saver']}
      ..serviceResponses['/rosapi/services'] = {'services': ['/map_saver/save_map']}
      ..serviceResponses['/map_saver/save_map'] = {'result': true};
    addTearDown(robot.close);
    final drive = DriveController(RosClient(robot))
      ..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    addTearDown(drive.dispose);
    final folder = Directory.systemTemp.createTempSync('maps');
    addTearDown(() => folder.deleteSync(recursive: true));
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: MapVisualizationPage(ip: 'robot', port: '9090',
        connectionFactory: (_, _) => robot, mapping: true, drive: drive, mapFolder: () async => folder)));
    await tester.pump();
    robot.events.add(_grid(4, 4, [for (var i = 0; i < 16; i++) i < 8 ? 0 : -1]));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('Make a map'), findsOneWidget);
    expect(tester.widget<SegmentedButton<String>>(find.byKey(const Key('map-tool'))).selected, {'map'});
    expect(find.byKey(const Key('pose-auto')), findsNothing, reason: 'the mapper knows where the robot is');
    expect(find.text('Making a map'), findsOneWidget);
    expect(find.textContaining('2.0 m² mapped · slam_toolbox'), findsOneWidget);

    // Push the stick up: the robot is driven forward, slowly; letting go stops it.
    final stick = find.byKey(const Key('mapping-stick'));
    final g = await tester.startGesture(tester.getCenter(stick));
    await g.moveBy(const Offset(0, -40));
    await tester.pump(const Duration(milliseconds: 200));
    final moving = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel');
    expect((moving['msg']['linear']['x'] as num), greaterThan(0));
    expect((moving['msg']['linear']['x'] as num), lessThanOrEqualTo(0.5 * 0.6 + 1e-9), reason: 'Normal preset');
    await g.up();
    await tester.pump(const Duration(milliseconds: 200));
    final stopped = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel');
    expect(stopped['msg']['linear']['x'], 0);

    await tester.tap(find.byKey(const Key('save-map')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.enterText(find.byKey(const Key('save-map-name')), 'first floor');
    await tester.tap(find.byKey(const Key('save-map-confirm')));
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && find.byKey(const Key('map-save-note')).evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pump();
    expect(robot.calls.where((c) => c.$1 == '/map_saver/save_map').single.$2['map_url'], 'first_floor');
    expect(find.text('Saved "first_floor" on the robot and on this phone.'), findsOneWidget);
    expect(utf8.decode(File('${folder.path}/first_floor.yaml').readAsBytesSync()), contains('image: first_floor.pgm'));
    expect(File('${folder.path}/first_floor.pgm').existsSync(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
