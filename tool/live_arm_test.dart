// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of the arm controls against a running ROS 2 arm (scripts/mock_arm.py or a real
// ros2_control arm on /arm_controller/joint_trajectory). Run explicitly:
//   flutter test tool/live_arm_test.dart --dart-define=ROBOT_HOST=172.30.1.17 --dart-define=ROBOT_PORT=9090
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

class Observer {
  late final RosConnection connection;
  final joints = <String, double>{};
  double lastCmdVelX = 0;

  Future<void> start() async {
    connection = RosConnection(host, port);
    await connection.ready;
    connection.messages.listen((event) {
      final msg = event['msg'];
      if (msg is! Map) return;
      if (event['topic'] == '/joint_states') {
        final names = List<String>.from(msg['name'] as List);
        final values = (msg['position'] as List).map((v) => (v as num).toDouble()).toList();
        for (var i = 0; i < names.length; i++) {
          joints[names[i]] = values[i];
        }
      } else if (event['topic'] == '/cmd_vel') {
        lastCmdVelX = (msg['linear']['x'] as num).toDouble();
      }
    });
    connection.send({'op': 'subscribe', 'topic': '/joint_states', 'throttle_rate': 50});
    connection.send({'op': 'subscribe', 'topic': '/cmd_vel'});
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

  testWidgets('arm mode jogs, drags, holds on STOP, homes; drive mode still reaches the base', (tester) async {
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
    double j1() => observer.joints['joint1'] ?? double.nan;

    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: host, port: port, channel: channel)));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty, 'type picker');
    expect(find.textContaining('Robot arm · /arm_controller/joint_trajectory'), findsOneWidget);
    print('suggested: ${tester.widget<Text>(find.textContaining('Suggested from')).data}');
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    final mobile = find.byKey(const Key('mode-toggle')).evaluate().isNotEmpty; // fixed arms have no toggle
    if (mobile) await tester.tap(find.text('Arm'));
    await waitFor(tester, () => find.byKey(const Key('jog-joint1-plus')).evaluate().isNotEmpty, 'arm panel with joint_states');
    await waitFor(tester, () => !j1().isNaN, '/joint_states in the observer');

    // 1. one +5 degree jog
    final before = j1();
    await tester.tap(find.byKey(const Key('jog-joint1-plus')));
    await tester.pump();
    await waitFor(tester, () => (j1() - before - 0.0873).abs() < 0.02, 'joint1 to move +5°', timeout: const Duration(seconds: 5));
    print('jog: joint1 ${before.toStringAsFixed(3)} -> ${j1().toStringAsFixed(3)} rad');

    // 2. drag joint1 to its upper limit (slow preset: long move), STOP midway must hold it
    await tester.drag(find.byKey(const Key('joint-joint1')), const Offset(600, 0));
    await tester.pump();
    await settle(tester, const Duration(seconds: 2));
    final moving = j1();
    expect(moving, greaterThan(before + 0.2), reason: 'the drag started a move toward the limit');
    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    await settle(tester, const Duration(milliseconds: 500));
    final held = j1();
    await settle(tester, const Duration(seconds: 2));
    expect((j1() - held).abs(), lessThan(0.02), reason: 'STOP holds position');
    expect(j1(), lessThan(2.7), reason: 'stopped before reaching the 2.827 limit');
    print('drag+STOP: moving ${moving.toStringAsFixed(2)}, held at ${j1().toStringAsFixed(2)} rad');

    // 3. Home returns to zero
    await tester.tap(find.byKey(const Key('preset-fast')));
    await tester.tap(find.byKey(const Key('arm-home')));
    await tester.pump();
    await waitFor(tester, () => j1().abs() < 0.02, 'joint1 to return home', timeout: const Duration(seconds: 15));
    print('home: joint1 ${j1().toStringAsFixed(3)} rad');

    // 3b. gripper (GripperCommand action through rosbridge), when the robot has one
    if (find.byKey(const Key('gripper-open')).evaluate().isNotEmpty) {
      double grip() => observer.joints['gripper_left_joint'] ?? double.nan;
      await tester.tap(find.byKey(const Key('gripper-open')));
      await tester.pump();
      await waitFor(tester, () => grip() > 0.012, 'gripper to open', timeout: const Duration(seconds: 10));
      final opened = grip();
      await tester.tap(find.byKey(const Key('gripper-close')));
      await tester.pump();
      await waitFor(tester, () => grip() < opened - 0.01, 'gripper to close', timeout: const Duration(seconds: 10));
      print('gripper: opened to ${opened.toStringAsFixed(3)} m, closed to ${grip().toStringAsFixed(3)} m');
    }

    // 4. back to Drive: the base still gets /cmd_vel (mobile manipulators only)
    if (!mobile) {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pump(const Duration(seconds: 6));
      return;
    }
    await tester.tap(find.text('Drive'));
    await tester.pump();
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-left'))));
    for (var i = 0; i < 6; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 20));
    }
    await waitFor(tester, () => observer.lastCmdVelX > 0.05, 'a forward /cmd_vel', timeout: const Duration(seconds: 5));
    await gesture.up();
    await waitFor(tester, () => observer.lastCmdVelX == 0, 'the stop /cmd_vel', timeout: const Duration(seconds: 5));
    print('drive mode: /cmd_vel forward then stop received');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
