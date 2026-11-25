// ignore_for_file: avoid_print -- progress output is the point of this manual check
// The map-screen tools against a real Nav2 (TurtleBot3 simulation):
//   bash scripts/dev-env/sim_live_test.sh tool/live_nav_tools_test.dart      (DISTRO=jazzy|lyrical)
// Lists what the robot offers (costmap services, FollowWaypoints, docking, collision monitor), clears the
// costmaps, reads both costmaps, runs a patrol of two places, tries to dock at a dock that is not in the
// database (Nav2 answers with its error code) and watches the collision monitor while the robot drives.

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/collision_watch.dart';
import 'package:ros_tester/costmap_layer.dart';
import 'package:ros_tester/docking.dart';
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
  
  test('docking at an unknown dock fails with the error code of Nav2', () async {
    final caps = await session.capabilities();
    final dock = DockController(RosClient(connection))..configure(caps.actionServers);
    print('dock actions: dock ${dock.canDock}, undock ${dock.canUndock}');
    expect(dock.canDock, isTrue);
    final status = await dock.dockAt('no_such_dock').timeout(const Duration(seconds: 60));
    print('dock: ${status.name}, error ${dock.errorCode}, "${dock.detail}"');
    expect(status, DockStatus.failed);
    expect(dock.errorCode, isNotNull);
    dock.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('the collision monitor reports while the robot drives at a wall', () async {
    final caps = await session.capabilities();
    final topics = {for (var i = 0; i < caps.topicNames.length; i++) caps.topicNames[i]: '${caps.topics!['types'][i]}'};
    final topic = collisionTopicIn(topics);
    print('collision monitor topic: $topic');
    if (topic == null) {
      print('  (this robot has no collision monitor)');
      return;
    }
    final seen = <String>[];
    final watch = CollisionWatch();
    final ros = RosClient(connection);
    final sub = ros.subscribe(topic).listen((m) {
      watch.onMessage(m, DateTime.now());
      seen.add('${m['action_type']}:${m['polygon_name']}');
    });
    // The monitor works on what Nav2 sends it (cmd_vel_smoothed), not on /cmd_vel after it: driving there
    // is what a person's stick does on a robot whose mux feeds the monitor.
    final input = topics.containsKey('/cmd_vel_smoothed') ? '/cmd_vel_smoothed' : '/cmd_vel';
    print('driving through $input');
    final cmd = ros.advertise(input, session.drive.stamped ? 'geometry_msgs/msg/TwistStamped' : 'geometry_msgs/msg/Twist');
    for (var i = 0; i < 150; i++) {
      cmd.publish(session.drive.stamped
          ? {'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': 'base_link'}, 'twist': {'linear': {'x': 0.3, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}}}
          : {'linear': {'x': 0.3, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    print('while driving: ${seen.length} messages ${seen.toList()}, now ${watch.current()}');
    for (var i = 0; i < 40; i++) { // stop sending: does it let go, and does it say so?
      cmd.publish(session.drive.stamped
          ? {'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': 'base_link'}, 'twist': {'linear': {'x': 0.0, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}}}
          : {'linear': {'x': 0.0, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    print('after stopping: ${seen.length} messages ${seen.toList()}, now ${watch.current()}');
    await sub.cancel();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
