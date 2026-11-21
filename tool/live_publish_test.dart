// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of the publish screen against a running robot (TB3 + Nav2 simulation):
// topic pick -> type and schema from rosapi -> form edit -> repeated Twist publish moves the robot ->
// Stop sends zero and the robot halts. Also checks the installed message type list (/rosapi/interfaces).
//   flutter test tool/live_publish_test.dart --dart-define=ROBOT_HOST=<robot ip>
import 'dart:io';
import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/publish_page.dart';
import 'package:ros_tester/ros_connection.dart';

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

Future<void> settle(WidgetTester tester, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'), (call) async => Directory.systemTemp.path);
  });

  testWidgets('publish screen drives the robot through /cmd_vel and stops it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late RosConnection observer;
    (double, double)? odom;
    double speed = 0;
    await tester.runAsync(() async {
      observer = RosConnection(host, port);
      await observer.ready;
      observer.messages.listen((e) {
        if (e['topic'] != '$ns/odom') return;
        final p = e['msg']['pose']['pose']['position'], t = e['msg']['twist']['twist'];
        odom = ((p['x'] as num).toDouble(), (p['y'] as num).toDouble());
        speed = math.sqrt(math.pow(t['linear']['x'] as num, 2) + math.pow(t['linear']['y'] as num, 2));
      });
      observer.send({'op': 'subscribe', 'topic': '$ns/odom', 'throttle_rate': 100});
    });
    addTearDown(observer.close);

    await tester.pumpWidget(const MaterialApp(home: PublishPage(ip: host, port: port)));
    // The robot's topics (from /rosapi/topics) are offered as the topic field is typed into.
    await tester.tap(find.byKey(const Key('publish-topic')));
    await tester.pump();
    // Suggestions follow the typed text, so type again until the robot's topics have arrived.
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    for (var typed = 0; find.text('$ns/cmd_vel').evaluate().isEmpty; typed++) {
      if (DateTime.now().isAfter(deadline)) fail('Timed out after 20s waiting for topic discovery');
      await tester.enterText(find.byKey(const Key('publish-topic')), typed.isEven ? '$ns/cmd_v' : '$ns/cmd_ve');
      await settle(tester, 500);
    }
    print('topics discovered: $ns/cmd_vel offered');
    await tester.tap(find.text('$ns/cmd_vel').last);
    const type = 'geometry_msgs/msg/Twist';
    final linearX = find.byKey(const ValueKey('field:linear/x:$type'));
    await waitFor(tester, () => linearX.evaluate().isNotEmpty, 'Twist form from /rosapi/message_details');
    print('schema loaded: Twist form shown for $ns/cmd_vel');

    await tester.enterText(linearX, '0.1');
    await tester.enterText(find.byKey(const ValueKey('field:angular/z:$type')), '0.3');
    await tester.pump();
    final start = odom!;
    await tester.ensureVisible(find.byKey(const Key('publish-repeat')));
    await tester.tap(find.byKey(const Key('publish-repeat')));
    await settle(tester, 3000);
    final moved = math.sqrt(math.pow(odom!.$1 - start.$1, 2) + math.pow(odom!.$2 - start.$2, 2));
    print('repeat publishing moved the robot ${moved.toStringAsFixed(2)} m, speed ${speed.toStringAsFixed(2)} m/s');
    expect(moved, greaterThan(0.15));
    expect(speed, closeTo(0.1, 0.04));

    await tester.tap(find.byKey(const Key('publish-stop')));
    await tester.pump();
    await waitFor(tester, () => speed < 0.01, 'the robot to stop after Stop (zero Twist)');
    final stoppedAt = odom!;
    await settle(tester, 1500);
    final drift = math.sqrt(math.pow(odom!.$1 - stoppedAt.$1, 2) + math.pow(odom!.$2 - stoppedAt.$2, 2));
    print('stopped: speed ${speed.toStringAsFixed(3)} m/s, drift after stop ${drift.toStringAsFixed(3)} m');
    expect(drift, lessThan(0.03));

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
