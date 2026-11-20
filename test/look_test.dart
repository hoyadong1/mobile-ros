import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

/// A 1x1 JPEG is not needed: the app passes compressed frames through untouched.
final fakeJpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9]);

class Scripted extends AgentBackend {
  Scripted(this.calls);
  final List<SkillCall> calls;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls);
}

void main() {
  late FakeConnection robot;
  late DriveController drive;
  late NavigationController nav;
  final camera = RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/image_raw/compressed');

  setUp(() {
    robot = FakeConnection();
    final ros = RosClient(robot);
    drive = DriveController(ros)..configure(camera, RosVersion.ros2);
    nav = NavigationController(ros);
  });
  tearDown(() {
    drive.dispose();
    nav.dispose();
  });

  test('look is offered only when the robot has a ROS camera topic', () {
    expect(AgentManifest.build(profile: camera).skill('look'), isNotNull);
    expect(AgentManifest.build(profile: camera).describe(), contains('camera (/camera/image_raw/compressed)'));
    expect(AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential)).skill('look'), isNull,
        reason: 'no camera chosen');
  });

  test('look returns the compressed frame as it is, and the log keeps it', () async {
    final agent = RobotAgent(drive: drive, nav: nav, backend: Scripted([const SkillCall('look')]));
    final running = agent.handle('뭐가 보여?');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final sub = robot.sent.lastWhere((m) => m['op'] == 'subscribe');
    expect(sub['topic'], '/camera/image_raw/compressed');
    robot.events.add({'op': 'publish', 'topic': '/camera/image_raw/compressed',
      'msg': {'format': 'rgb8; jpeg compressed bgr8', 'data': base64Encode(fakeJpeg)}});
    final run = await running;
    expect(run.ok, isTrue);
    final r = run.results.single;
    expect(r.image, fakeJpeg);
    expect(r.imageType, 'image/jpeg');
    expect(agent.log.entries.last.image, fakeJpeg, reason: 'shown in the assistant history');
    expect(robot.sent.where((m) => m['op'] == 'unsubscribe' && m['topic'] == '/camera/image_raw/compressed'),
        hasLength(1), reason: 'one frame, then the camera is released');
  });

  testWidgets('a raw frame is converted to PNG', (tester) async {
    final raw = RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/image_raw');
    drive.configure(raw, RosVersion.ros2);
    final agent = RobotAgent(drive: drive, nav: nav, backend: Scripted([const SkillCall('look')]));
    final run = await tester.runAsync(() async {
      final running = agent.handle('look');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      robot.events.add({'op': 'publish', 'topic': '/camera/image_raw', 'msg': {
        'encoding': 'rgb8', 'width': 2, 'height': 1, 'step': 6, 'data': base64Encode([255, 0, 0, 0, 255, 0])}});
      return running;
    });
    final r = run!.results.single;
    expect(r.imageType, 'image/png');
    expect(r.image!.sublist(1, 4), utf8.encode('PNG'));
    drive.dispose(); // its drive loop timer was started inside this widget test's clock
  });

  test('the cloud request carries the picture inside the tool result', () async {
    final bodies = <Map<String, dynamic>>[];
    var turn = 0;
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      final reply = turn++ == 0
          ? {'stop_reason': 'tool_use', 'content': [{'type': 'tool_use', 'id': 'l1', 'name': 'look', 'input': {}}]}
          : {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': '상자가 보여요.'}]};
      return http.Response(jsonEncode(reply), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final agent = RobotAgent(drive: drive, nav: nav,
        backend: CloudBackend(endpoint: Uri.parse('http://pc/v1/plan'), client: client));
    final running = agent.handle('앞에 뭐 있어?');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    robot.events.add({'op': 'publish', 'topic': '/camera/image_raw/compressed',
      'msg': {'format': 'jpeg', 'data': base64Encode(fakeJpeg)}});
    final run = await running;
    expect(run.replies.last, '상자가 보여요.');
    final result = ((bodies[1]['messages'] as List).last['content'] as List).single as Map;
    final parts = result['content'] as List;
    expect(parts.first['type'], 'text');
    expect(parts.last['source'], {'type': 'base64', 'media_type': 'image/jpeg', 'data': base64Encode(fakeJpeg)});
  });
}
