import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/explorer_page.dart';
import 'package:ros_tester/map_page.dart';
import 'package:ros_tester/monitor_page.dart';
import 'package:ros_tester/publish_page.dart';
import 'package:ros_tester/robot_profile.dart';
import 'support/fake_ros_connection.dart';

void main() {
  testWidgets('control camera uses the workspace DDS factory with an empty IP', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile::0': jsonEncode(
      const RobotProfile(drive: DriveType.differential, commandTopic: '/cmd_vel',
        cameraTopic: '/demo_camera/image_raw/compressed').toJson())});
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection();
    final camera = FakeConnection();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: '', port: '0', connection: robot,
      connectionFactory: (host, domain) {
        expect(host, isEmpty);
        expect(domain, '0');
        return camera;
      })));
    await tester.ensureVisible(find.byKey(const Key('tool-control')));
    await tester.tap(find.byKey(const Key('tool-control')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(camera.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' &&
      m['topic'] == '/demo_camera/image_raw/compressed')));
    camera.events.add({'op': 'status', 'level': 'error', 'msg': 'Camera message definition missing'});
    await tester.pump();
    expect(find.textContaining('Camera message definition missing'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  for (final scale in [1.5, 2.0]) {
  for (final page in ['workspace', 'explorer', 'map', 'sensors', 'publish', 'control']) {
    testWidgets('$page fits small screens with text scale $scale', (tester) async {
      SharedPreferences.setMockInitialValues({'robot_profile:robot:0': jsonEncode(
        const RobotProfile(drive: DriveType.differential, commandTopic: '/cmd_vel').toJson())});
      await tester.binding.setSurfaceSize(page == 'control' ? const Size(640, 360) : const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
        'topics': ['/cmd_vel', '/robot/front/camera/image_raw/compressed', '/robot/battery_state'],
        'types': ['geometry_msgs/msg/Twist', 'sensor_msgs/msg/CompressedImage', 'sensor_msgs/msg/BatteryState'],
      };
      final camera = FakeConnection();
      FakeConnection factory(String a, String b) => robot;
      final Widget screen = switch (page) {
        'workspace' => MainPage(ip: 'robot', port: '0', connection: robot, connectionFactory: factory),
        'explorer' => ExplorerPage(ip: 'robot', port: '0', connectionFactory: factory),
        'map' => MapVisualizationPage(ip: 'robot', port: '0', connectionFactory: factory),
        'sensors' => SensorPage(ip: 'robot', port: '0', connectionFactory: factory),
        'publish' => PublishPage(ip: 'robot', port: '0', connectionFactory: factory),
        _ => ControlScreen(ip: 'robot', port: '0', channel: robot, imageConnectionFactory: (a,b) => camera),
      };
      await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!), home: screen));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
      if (page == 'control') {
        await tester.tap(find.byKey(const Key('control-settings')));
        await tester.pump();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
      if (!robot.isClosed) robot.close();
      if (!camera.isClosed) camera.close();
    });
  }
  }
}
