// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of the omnidirectional and car-like controllers against Gazebo vehicles
// (scripts/ros2_vehicle_sim.sh omni|car). Run explicitly, matching the running simulation:
//   flutter test tool/live_vehicle_test.dart --dart-define=ROBOT_HOST=172.30.1.17 --dart-define=VEHICLE=omni
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const vehicle = String.fromEnvironment('VEHICLE', defaultValue: 'omni');

class Pose {
  final double x, y, yaw;
  const Pose(this.x, this.y, this.yaw);
  double distanceTo(Pose o) => math.sqrt(math.pow(x - o.x, 2) + math.pow(y - o.y, 2));
  double yawTo(Pose o) => math.atan2(math.sin(o.yaw - yaw), math.cos(o.yaw - yaw));
  @override
  String toString() => '(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${(yaw * 57.3).toStringAsFixed(0)}°)';
}

class Observer {
  late final RosConnection connection;
  Pose? pose;

  Future<void> start() async {
    connection = RosConnection(host, port);
    await connection.ready;
    connection.messages.listen((event) {
      if (event['topic'] != '/demo/odom_demo' || event['msg'] is! Map) return;
      final p = event['msg']['pose']['pose'];
      final q = p['orientation'];
      final yaw = math.atan2(2 * ((q['w'] as num) * (q['z'] as num) + (q['x'] as num) * (q['y'] as num)),
          1 - 2 * (math.pow(q['y'] as num, 2) + math.pow(q['z'] as num, 2)));
      pose = Pose((p['position']['x'] as num).toDouble(), (p['position']['y'] as num).toDouble(), yaw.toDouble());
    });
    connection.send({'op': 'subscribe', 'topic': '/demo/odom_demo', 'throttle_rate': 50});
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

/// Holds [stick] pushed by [offset] for [hold], then releases and lets the vehicle stop.
Future<void> push(WidgetTester tester, List<(String, Offset)> sticks, Duration hold) async {
  final gestures = <TestGesture>[];
  for (final (key, _) in sticks) {
    gestures.add(await tester.startGesture(tester.getCenter(find.byKey(Key(key))), pointer: gestures.length + 1));
  }
  for (var i = 0; i < 6; i++) {
    for (var g = 0; g < sticks.length; g++) {
      await gestures[g].moveBy(sticks[g].$2 / 6);
    }
    await tester.pump(const Duration(milliseconds: 20));
  }
  await settle(tester, hold);
  for (final g in gestures) {
    await g.up();
  }
  await settle(tester, const Duration(milliseconds: 1500));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  testWidgets('$vehicle: motion only that drive type can make', (tester) async {
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
    print('suggested: ${tester.widget<Text>(find.textContaining('Suggested from')).data}');
    if (vehicle == 'omni') {
      // A Twist topic alone cannot reveal sideways motion: the user picks the type.
      await tester.tap(find.byKey(const Key('type-holonomic')));
      await tester.pump();
    } else {
      expect(find.textContaining('Car-like · /ackermann_cmd'), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('preset-fast')));
    await waitFor(tester, () => observer.pose != null, 'odometry');

    if (vehicle == 'omni') {
      // 1. left stick pushed left: pure sideways motion, no turning
      final a = observer.pose!;
      await push(tester, [('stick-left', const Offset(-70, 0))], const Duration(seconds: 3));
      final b = observer.pose!;
      final dx = (b.x - a.x) * math.cos(a.yaw) + (b.y - a.y) * math.sin(a.yaw); // body frame
      final dy = -(b.x - a.x) * math.sin(a.yaw) + (b.y - a.y) * math.cos(a.yaw);
      print('sideways: $a -> $b  (body forward ${dx.toStringAsFixed(2)} m, left ${dy.toStringAsFixed(2)} m)');
      expect(dy, greaterThan(0.5), reason: 'moved to the left');
      expect(dx.abs(), lessThan(0.15), reason: 'without driving forward');
      expect(a.yawTo(b).abs(), lessThan(0.1), reason: 'without turning');

      // 2. right stick: rotate in place
      await push(tester, [('stick-right', const Offset(-70, 0))], const Duration(seconds: 2));
      final c = observer.pose!;
      print('rotate: $b -> $c');
      expect(b.yawTo(c), greaterThan(0.5), reason: 'turned left');
      expect(b.distanceTo(c), lessThan(0.15), reason: 'in place');
    } else {
      // 1. steering alone: a car cannot turn in place
      final a = observer.pose!;
      await push(tester, [('stick-right', const Offset(-70, 0))], const Duration(seconds: 2));
      final b = observer.pose!;
      print('steer only: $a -> $b');
      expect(a.distanceTo(b), lessThan(0.1), reason: 'no throttle, no motion');
      expect(a.yawTo(b).abs(), lessThan(0.05), reason: 'no turning in place');

      // 2. throttle + steer left: drives forward along a left arc
      await push(tester, [('stick-left', const Offset(0, -70)), ('stick-right', const Offset(-70, 0))],
          const Duration(seconds: 5));
      final c = observer.pose!;
      final forward = (c.x - b.x) * math.cos(b.yaw) + (c.y - b.y) * math.sin(b.yaw);
      print('throttle+steer left: $b -> $c  (forward ${forward.toStringAsFixed(2)} m, turned '
          '${(b.yawTo(c) * 57.3).toStringAsFixed(0)}°)');
      expect(forward, greaterThan(1.0), reason: 'drove forward');
      // Full right stick on Fast = max steering 0.4 rad. Bicycle model: yaw = distance * tan(steer) / wheelbase
      // (Prius 2.86 m). The stick is not at full deflection the whole time, so allow a band below that.
      final predicted = forward * math.tan(0.4) / 2.86;
      print('  bicycle-model yaw at full steer: ${(predicted * 57.3).toStringAsFixed(0)}°');
      expect(b.yawTo(c), greaterThan(predicted * 0.5), reason: 'curved left about as the steering angle implies');
      expect(b.yawTo(c), lessThan(predicted * 1.2));

      // 3. released: the car stops
      final d = observer.pose!;
      await settle(tester, const Duration(seconds: 2));
      print('stopped: drift ${d.distanceTo(observer.pose!).toStringAsFixed(2)} m over 2 s');
      expect(d.distanceTo(observer.pose!), lessThan(0.2));
    }

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
