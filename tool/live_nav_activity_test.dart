// What Nav2 is doing, read from its behavior tree log, against the TurtleBot3 + Nav2 simulation:
//   bash scripts/dev-env/sim_live_test.sh tool/live_nav_activity_test.dart   (DISTRO=jazzy for Jazzy)
// A reachable goal shows planning and following; a goal Nav2 cannot reach shows its recoveries.
// ignore_for_file: avoid_print -- progress output is the point of this manual check
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/nav_activity.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live: planning, following and recoveries are seen', () async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    final connection = RosConnection(host, port);
    await connection.ready;
    final session = RobotSession(connection: connection, ip: host, port: port);
    addTearDown(() { session.dispose(); connection.close(); });
    await session.prepare();
    final nav = session.nav;
    print('navigation: ${nav.label}');
    expect(nav.mode, NavMode.action);

    Future<(NavStatus, List<NavActivity>, int)> trip(Pose2D target, Duration limit) async {
      final seen = <NavActivity>[];
      void watch() {
        final a = nav.activity;
        if (a != null && (seen.isEmpty || seen.last != a)) {
          seen.add(a);
          print('  ${DateTime.now().toIso8601String().substring(11, 19)} ${a.name}');
        }
      }
      nav.addListener(watch);
      final status = await nav.goTo(target).timeout(limit, onTimeout: () {
        nav.cancel();
        return NavStatus.canceled;
      });
      nav.removeListener(watch);
      return (status, seen, nav.activityTracker.recoveryActions);
    }

    print('reachable goal (0.5, 0.5):');
    final (ok, okSeen, _) = await trip(const Pose2D(0.5, 0.5, 0), const Duration(seconds: 90));
    print('-> $ok, activities $okSeen');
    expect(ok, NavStatus.succeeded);
    expect(okSeen, contains(NavActivity.following));

    print('unreachable goal (9, 9), outside the map:');
    final (bad, badSeen, recoveries) = await trip(const Pose2D(9, 9, 0), const Duration(seconds: 120));
    print('-> $bad, activities $badSeen, recovery actions $recoveries, last ${nav.activityTracker.lastRecovery}');
    expect(bad, isNot(NavStatus.succeeded));
    expect(badSeen.any(isRecovery), isTrue, reason: 'Nav2 recovers before it gives up');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
