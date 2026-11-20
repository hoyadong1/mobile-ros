// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of the sensor screen's IMU card on a vehicle that really rotates: PX4 SITL
// (scripts/ros2_drone_sim.sh) spun in place by scripts/drone_spin.py. Start the spin, then run:
//   flutter test tool/live_imu_test.dart --dart-define=ROBOT_HOST=<robot ip>
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/monitor_page.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/sensors.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const imuTopic = String.fromEnvironment('IMU_TOPIC', defaultValue: '/mavros/imu/data');

Future<void> waitFor(WidgetTester tester, bool Function() done, String what,
    {Duration timeout = const Duration(seconds: 30)}) async {
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

  testWidgets('IMU card follows a real rotation and matches the topic', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late RosConnection raw;
    final rawRates = <(DateTime, double)>[];
    await tester.runAsync(() async {
      raw = RosConnection(host, port);
      await raw.ready;
      raw.messages.listen((e) {
        if (e['topic'] == imuTopic) {
          rawRates.add((DateTime.now(), (e['msg']['angular_velocity']['z'] as num) * 57.29578));
        }
      });
      raw.send({'op': 'subscribe', 'topic': imuTopic, 'throttle_rate': 100});
    });
    addTearDown(raw.close);

    await tester.pumpWidget(const MaterialApp(home: SensorPage(ip: host, port: port)));
    SensorPageState state() => tester.state<SensorPageState>(find.byType(SensorPage));
    await waitFor(tester, () => state().feeds != null, 'sensor discovery');
    final imu = state().feeds!.where((f) => f.source.topic == imuTopic).firstOrNull;
    print('found: ${state().feeds!.map((f) => f.source.topic).join(', ')}');
    expect(imu, isNotNull, reason: '$imuTopic is listed as an IMU card');
    expect(imu!.source.kind, SensorKind.imu);

    await waitFor(tester, () => (imu.latest?.plot?.abs() ?? 0) > 24, 'the IMU card to show the full spin rate',
        timeout: const Duration(seconds: 60));
    // The gyro is noisy and the card and this reference sample at different instants: compare 2 s means.
    final from = DateTime.now();
    await waitFor(tester, () => DateTime.now().difference(from) > const Duration(seconds: 2), '2 s of samples');
    double mean(Iterable<double> v) => v.reduce((a, b) => a + b) / v.length;
    final card = mean(imu.history.where((e) => !e.$1.isBefore(from)).map((e) => e.$2));
    final topic = mean(rawRates.where((e) => !e.$1.isBefore(from)).map((e) => e.$2));
    final shown = imu.latest!;
    print('IMU card: ${shown.headline}; ${shown.details.map((d) => '${d.$1} ${d.$2}').join(', ')}');
    print('2 s mean turn rate: card ${card.toStringAsFixed(1)} °/s, topic ${topic.toStringAsFixed(1)} °/s');
    expect(card, closeTo(topic, 2), reason: 'the card shows what the topic says');
    // PX4 tracks the commanded 0.5 rad/s loosely (about 36 °/s in SIH); the point is a real rotation.
    expect(card.abs(), greaterThan(20), reason: 'the vehicle is really turning');
    expect(imu.history.length, greaterThan(5), reason: 'trend chart has points');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
