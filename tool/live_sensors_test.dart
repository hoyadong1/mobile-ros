// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of the sensor screen against a running robot (any simulation; TB3 + Nav2 has /scan, /imu,
// /odom). It drives the robot in a slow circle and expects odometry speed to follow, and the IMU card to
// match an independent /imu subscription. (TB3's Gazebo IMU plugin reports ~0 turn rate even while the
// wheels turn the robot, so the IMU is compared with the topic, not with the commanded motion.)
//   flutter test tool/live_sensors_test.dart --dart-define=ROBOT_HOST=<robot ip>
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/monitor_page.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/sensors.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
/// Robot namespace, e.g. `--dart-define=NS=/robot1` with scripts/ros2_ns_sim.sh.
const ns = String.fromEnvironment('NS');

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
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('sensor screen shows live LiDAR, IMU and odometry that follow the robot', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late RosConnection driver;
    double? rawTurnRate; // °/s, straight from /imu
    await tester.runAsync(() async {
      driver = RosConnection(host, port);
      await driver.ready;
      driver.messages.listen((e) {
        if (e['topic'] == '$ns/imu') rawTurnRate = (e['msg']['angular_velocity']['z'] as num) * 180 / 3.141592653589793;
      });
      driver.send({'op': 'advertise', 'topic': '$ns/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
      driver.send({'op': 'subscribe', 'topic': '$ns/imu', 'throttle_rate': 100});
    });
    addTearDown(driver.close);

    await tester.pumpWidget(const MaterialApp(home: SensorPage(ip: host, port: port)));
    SensorPageState state() => tester.state<SensorPageState>(find.byType(SensorPage));
    await waitFor(tester, () => state().feeds != null, 'sensor discovery');
    final feeds = state().feeds!;
    print('found: ${feeds.map((f) => '${f.source.kind.label} ${f.source.topic}').join(', ')}'
        '${state().inactiveTopics > 0 ? ' (${state().inactiveTopics} without a publisher hidden)' : ''}');
    for (final f in feeds) {
      expect(f.source.topic, startsWith('$ns/'), reason: 'only topics that are actually published');
    }
    SensorFeed feed(SensorKind k) => feeds.firstWhere((f) => f.source.kind == k);
    for (final k in [SensorKind.laser, SensorKind.imu, SensorKind.odometry]) {
      await waitFor(tester, () => feed(k).latest != null, '${k.label} data');
    }
    await waitFor(tester, () => feed(SensorKind.laser).rate(DateTime.now()) > 1, 'LiDAR rate');
    final laser = feed(SensorKind.laser).latest!;
    print('LiDAR: ${laser.headline}, ${laser.details.map((d) => '${d.$1} ${d.$2}').join(', ')}, '
        '${feed(SensorKind.laser).rate(DateTime.now()).toStringAsFixed(1)} Hz shown');
    expect(laser.scan!.length, greaterThan(50));
    expect(find.byType(ScanView), findsWidgets);
    print('IMU at rest: ${feed(SensorKind.imu).latest!.headline}; odom: ${feed(SensorKind.odometry).latest!.headline}');

    // Drive a tight slow circle (0.1 m/s, 0.5 rad/s: 0.2 m radius, fits between the TB3 world pillars).
    Future<void> drive(double v, double w, Duration d) async {
      final end = DateTime.now().add(d);
      while (DateTime.now().isBefore(end)) {
        driver.send({'op': 'publish', 'topic': '$ns/cmd_vel', 'msg': {
          'linear': {'x': v, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': w}}});
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await drive(0.1, 0.5, const Duration(seconds: 3));
    final odom = feed(SensorKind.odometry).latest!, imu = feed(SensorKind.imu).latest!;
    print('moving: odom ${odom.headline}; IMU ${imu.headline}, turn rate ${imu.plot?.toStringAsFixed(2)} °/s '
        '(raw /imu ${rawTurnRate?.toStringAsFixed(2)} °/s)');
    expect(odom.plot!, closeTo(0.1, 0.04));
    expect(imu.plot!, closeTo(rawTurnRate!, 1.0), reason: 'the IMU card shows what /imu publishes');
    expect(feed(SensorKind.odometry).history.length, greaterThan(10), reason: 'trend chart has points');
    await drive(0, 0, const Duration(seconds: 2));
    await waitFor(tester, () => feed(SensorKind.odometry).latest!.plot!.abs() < 0.02, 'odometry to show the stop',
        timeout: const Duration(seconds: 6));
    print('stopped: odom ${feed(SensorKind.odometry).latest!.headline}');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6)); // WebSocket.close() arms a 5 s fake-zone timer
  });
}
