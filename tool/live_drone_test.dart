// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live flight check against PX4 SITL + MAVROS + rosbridge (scripts/ros2_drone_sim.sh). Run explicitly:
//   flutter test tool/live_drone_test.dart --dart-define=ROBOT_HOST=172.30.1.17 --dart-define=ROBOT_PORT=9090
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

class Observer {
  late final RosConnection connection;
  math.Point<double>? xy;
  double z = 0;
  bool armed = false;
  String mode = '';

  Future<void> start() async {
    connection = RosConnection(host, port);
    await connection.ready;
    connection.messages.listen((event) {
      final msg = event['msg'];
      if (msg is! Map) return;
      if (event['topic'] == '/mavros/local_position/pose') {
        final p = msg['pose']['position'];
        xy = math.Point((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
      } else if (event['topic'] == '/mavros/global_position/rel_alt') {
        z = (msg['data'] as num).toDouble(); // above home; local z drifts with the EKF origin
      } else if (event['topic'] == '/mavros/state') {
        armed = msg['armed'] == true;
        mode = '${msg['mode']}';
      }
    });
    connection.send({'op': 'subscribe', 'topic': '/mavros/local_position/pose', 'throttle_rate': 100});
    connection.send({'op': 'subscribe', 'topic': '/mavros/state'});
    connection.send({'op': 'subscribe', 'topic': '/mavros/global_position/rel_alt', 'throttle_rate': 100});
  }
}

Future<void> waitFor(WidgetTester tester, bool Function() done, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out after ${timeout.inSeconds}s waiting for $what');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> settle(WidgetTester tester, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('take off, fly forward in OFFBOARD, hover on release, HOLD, land', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final observer = Observer();
    late RosConnection channel;
    await tester.runAsync(() async {
      await observer.start();
      channel = RosConnection(host, port);
      await channel.ready;
    });
    addTearDown(() { channel.close(); observer.connection.close(); });

    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: host, port: port, channel: channel)));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty, 'type picker');
    expect(find.textContaining('Drone · /mavros/setpoint_velocity/cmd_vel_unstamped'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-continue')));
    await waitFor(tester, () => find.textContaining('DISARMED').evaluate().isNotEmpty, 'flight controller connected');

    // 1. take off (long press only)
    await tester.longPress(find.byKey(const Key('drone-takeoff')));
    // PX4 switches to AUTO.LOITER once the takeoff altitude (default 2.5 m) is reached.
    await waitFor(tester, () => observer.armed && observer.mode == 'AUTO.LOITER' && observer.z > 2.0,
        'arming, climbing and finishing takeoff', timeout: const Duration(seconds: 40));
    await settle(tester, const Duration(seconds: 3));
    print('takeoff: armed, altitude ${observer.z.toStringAsFixed(2)} m, mode ${observer.mode}');

    // 2. right stick forward ~3 s: OFFBOARD engages and the vehicle moves
    await tester.tap(find.byKey(const Key('preset-normal')));
    final start = observer.xy!;
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-right'))));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await settle(tester, const Duration(seconds: 4));
    final moved = observer.xy!.distanceTo(start);
    print('stick forward: moved ${moved.toStringAsFixed(2)} m, mode ${observer.mode}, altitude ${observer.z.toStringAsFixed(2)} m');
    expect(observer.mode, 'OFFBOARD');
    expect(moved, greaterThan(1.0));

    // 3. release: brake, then PX4 position hold (AUTO.LOITER) keeps it in place
    await gesture.up();
    await waitFor(tester, () => observer.mode == 'AUTO.LOITER', 'centred sticks -> AUTO.LOITER',
        timeout: const Duration(seconds: 5));
    await settle(tester, const Duration(seconds: 3));
    final hoverAt = observer.xy!;
    await settle(tester, const Duration(seconds: 2));
    final drift = observer.xy!.distanceTo(hoverAt);
    print('release: drift ${drift.toStringAsFixed(2)} m over 2 s');
    expect(drift, lessThan(0.3));
    expect(observer.z, greaterThan(1.5), reason: 'still airborne');

    // 4. fly again, then HOLD mid-move
    final again = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-right'))));
    for (var i = 0; i < 6; i++) {
      await again.moveBy(const Offset(-12, 0));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await waitFor(tester, () => observer.mode == 'OFFBOARD', 'sticks retake OFFBOARD', timeout: const Duration(seconds: 5));
    await settle(tester, const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('estop')));
    await waitFor(tester, () => observer.mode == 'AUTO.LOITER', 'HOLD -> AUTO.LOITER', timeout: const Duration(seconds: 5));
    await settle(tester, const Duration(seconds: 2));
    expect(observer.mode, 'AUTO.LOITER', reason: 'a still-held stick must not retake control after HOLD');
    await again.up();
    print('HOLD: mode ${observer.mode} while the stick was still held');

    // 5. land
    await tester.tap(find.byKey(const Key('drone-land')));
    await waitFor(tester, () => !observer.armed && observer.z < 0.3, 'landing and auto-disarm',
        timeout: const Duration(seconds: 60));
    print('land: disarmed at altitude ${observer.z.toStringAsFixed(2)} m');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
