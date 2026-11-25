// ignore_for_file: avoid_print -- progress output is the point of this manual check
// The map-screen tools against a real Nav2 (TurtleBot3 simulation):
//   bash scripts/dev-env/sim_live_test.sh tool/live_nav_tools_test.dart      (DISTRO=jazzy|lyrical)
// Lists what the robot offers (costmap services, FollowWaypoints, docking, collision monitor), clears the
// costmaps, reads the local costmap, and runs a patrol of two places.

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/costmap_layer.dart';
import 'package:ros_tester/mapping.dart' show robotServices;
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/nav_tools.dart';
import 'package:ros_tester/patrol.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RosConnection connection;
  late RobotSession session;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    await session.prepare();
  });
  tearDownAll(() { session.dispose(); connection.close(); });

  test('what this Nav2 offers', () async {
    final services = await robotServices(connection);
    final tools = navToolsIn(services);
    print('costmap services: ${tools.clearLocal}, ${tools.clearGlobal}');
    final caps = await session.capabilities();
    print('actions: ${caps.actionServers.where((a) => !a.contains('_nav')).toList()}');
    print('collision monitor topics: ${caps.topicNames.where((t) => t.contains('collision')).toList()}');
    print('dock services/actions: ${[...services, ...caps.actionServers].where((s) => s.contains('dock')).toList()}');
    expect(tools.canClearCostmaps, isTrue);
  });

  test('clear the costmaps', () async {
    final tools = navToolsIn(await robotServices(connection));
    final cleared = await clearCostmaps(RosClient(connection), tools);
    print('cleared $cleared costmaps');
    expect(cleared, greaterThan(0));
  });

  test('read the local and the global costmap', () async {
    final caps = await session.capabilities();
    final topics = {for (var i = 0; i < caps.topicNames.length; i++) caps.topicNames[i]: '${caps.topics!['types'][i]}'};
    for (final kind in CostmapKind.values) {
      final topic = costmapTopicIn(topics, kind);
      print('${kind.name} costmap topic: $topic');
      expect(topic, isNotNull);
      final msg = await RosClient(connection).subscribe(topic!, throttleRate: 500).first.timeout(const Duration(seconds: 15));
      final c = Costmap.fromMessage(msg);
      print('  ${c == null ? 'refused' : '${c.width}x${c.height} @ ${c.resolution} m, frame ${c.frame}, '
          '${c.cells.where((v) => v > 0).length} cells with a cost'}');
      expect(c, isNotNull);
    }
  });

  test('a patrol through two places', () async {
    final caps = await session.capabilities();
    final patrol = PatrolController(RosClient(connection))..configure(caps.actionServers);
    print('follow_waypoints: ${patrol.action}');
    expect(patrol.available, isTrue);
    final status = await patrol.start(const [PatrolStop('a', Pose2D(0.5, 0.5, 0)), PatrolStop('b', Pose2D(-0.5, -0.5, 0))])
        .timeout(const Duration(minutes: 3));
    print('patrol: ${status.name}, missed ${patrol.missed}, current stop ${patrol.current}');
    expect(status, PatrolStatus.finished);
    patrol.dispose();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
