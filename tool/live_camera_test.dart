// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check: with both raw and JPEG-compressed camera topics on the robot, the control screen picks
// the compressed one and shows its frames. Any running simulation with a camera and
// scripts/compress_republisher.py works. Run explicitly:
//   flutter test tool/live_camera_test.dart --dart-define=ROBOT_HOST=172.30.1.17 --plain-name compressed
// MJPEG (web_video_server on the robot, no compressed topic):
//   flutter test tool/live_camera_test.dart --dart-define=ROBOT_HOST=<robot ip> --plain-name MJPEG
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');

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

  testWidgets('control screen prefers and shows the compressed camera stream', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late RosConnection channel;
    await tester.runAsync(() async {
      channel = RosConnection(host, port);
      await channel.ready;
    });
    addTearDown(channel.close);

    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: host, port: port, channel: channel)));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty, 'type picker');
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    final topic = tester.state<ControlScreenState>(find.byType(ControlScreen)).profile!.cameraTopic;
    print('camera topic chosen: $topic');
    expect(topic, endsWith('/compressed'));

    var frames = 0;
    Object? last;
    await waitFor(tester, () {
      final images = find.byKey(const Key('camera-image')).evaluate();
      if (images.isNotEmpty) {
        final image = (images.first.widget as RawImage).image;
        if (image != null && !identical(image, last)) { frames++; last = image; }
      }
      return frames >= 5;
    }, 'five decoded JPEG frames', timeout: const Duration(seconds: 15));
    final shown = (find.byKey(const Key('camera-image')).evaluate().first.widget as RawImage).image!;
    print('decoded $frames JPEG frames, ${shown.width}x${shown.height}');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('raw-only robot with web_video_server: MJPEG is suggested and shown', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    late RosConnection channel;
    await tester.runAsync(() async {
      channel = RosConnection(host, port);
      await channel.ready;
    });
    addTearDown(channel.close);

    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: host, port: port, channel: channel)));
    await waitFor(tester, () => find.byKey(const Key('profile-continue')).evaluate().isNotEmpty, 'type picker');
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    final profile = tester.state<ControlScreenState>(find.byType(ControlScreen)).profile!;
    print('camera: ${profile.cameraSource.name} ${profile.mjpegUrl}');
    expect(profile.cameraSource, CameraSource.mjpeg);

    var frames = 0;
    Object? last;
    await waitFor(tester, () {
      final images = find.byKey(const Key('camera-image')).evaluate();
      if (images.isNotEmpty) {
        final image = (images.first.widget as RawImage).image;
        if (image != null && !identical(image, last)) { frames++; last = image; }
      }
      return frames >= 5;
    }, 'five MJPEG frames', timeout: const Duration(seconds: 15));
    final shown = (find.byKey(const Key('camera-image')).evaluate().first.widget as RawImage).image!;
    print('decoded $frames MJPEG frames, ${shown.width}x${shown.height}');

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 12));
  });
}
