import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/nav_tools.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  const nav2 = ['/local_costmap/clear_entirely_local_costmap', '/global_costmap/clear_entirely_global_costmap',
    '/map_server/load_map'];

  test('the costmap services are found in a robot without a namespace', () {
    final t = navToolsIn(nav2);
    expect(t.clearLocal, '/local_costmap/clear_entirely_local_costmap');
    expect(t.clearGlobal, '/global_costmap/clear_entirely_global_costmap');
    expect(t.canClearCostmaps, isTrue);
    expect(navToolsIn(['/map_server/load_map']).canClearCostmaps, isFalse);
  });

  test('a robot in a namespace gets its own costmaps, never another robot\'s', () {
    final both = [
      '/robot1/local_costmap/clear_entirely_local_costmap', '/robot2/local_costmap/clear_entirely_local_costmap',
      '/robot2/global_costmap/clear_entirely_global_costmap',
    ];
    final r2 = navToolsIn(both, namespace: '/robot2');
    expect(r2.clearLocal, '/robot2/local_costmap/clear_entirely_local_costmap');
    expect(r2.clearGlobal, '/robot2/global_costmap/clear_entirely_global_costmap');
    final r1 = navToolsIn(both, namespace: '/robot1');
    expect(r1.clearLocal, '/robot1/local_costmap/clear_entirely_local_costmap');
    expect(r1.clearGlobal, isNull, reason: 'robot2\'s global costmap is not robot1\'s');
    expect(navToolsIn(both, namespace: '/robot3').canClearCostmaps, isFalse);
    expect(navToolsIn(nav2, namespace: '/robot1').clearLocal, '/local_costmap/clear_entirely_local_costmap',
        reason: 'a robot at the root of the graph is the only one there is');
  });

  test('clearing calls both services; one failing still counts, none answering throws', () async {
    final robot = FakeConnection()
      ..serviceResponses['/local_costmap/clear_entirely_local_costmap'] = {}
      ..serviceResponses['/global_costmap/clear_entirely_global_costmap'] = {};
    addTearDown(robot.close);
    expect(await clearCostmaps(RosClient(robot), navToolsIn(nav2)), 2);
    expect(robot.calls.map((c) => c.$1), ['/local_costmap/clear_entirely_local_costmap',
      '/global_costmap/clear_entirely_global_costmap']);

    await expectLater(clearCostmaps(RosClient(robot), NavTools.none), throwsStateError);
  });
}
