import 'dart:async';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamepads/gamepads.dart' show GamepadAxis, GamepadButton;
import 'package:ros_tester/keyboard_drive.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

const ros2Topics = {
  'topics': ['/cmd_vel', '/odom', '/camera/depth/image_raw', '/camera/color/image_raw'],
  'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/Image', 'sensor_msgs/msg/Image'],
};

Future<(FakeConnection, FakeConnection)> _open(WidgetTester tester, {Map<String, dynamic>? topics}) async {
  final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = topics ?? ros2Topics;
  final camera = FakeConnection();
  addTearDown(robot.close);
  addTearDown(camera.close);
  await tester.binding.setSurfaceSize(const Size(900, 420)); // phone in landscape
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: ControlScreen(
    ip: 'robot', port: '9090', channel: robot, imageConnectionFactory: (_, _) => camera)));
  await tester.pump();
  await tester.pump();
  return (robot, camera);
}

List<Map<String, dynamic>> _published(FakeConnection robot, String topic) =>
    robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == topic).toList();

Future<TestGesture> _drag(WidgetTester tester, String stick, Offset by) async {
  final gesture = await tester.startGesture(tester.getCenter(find.byKey(Key(stick))));
  for (var i = 0; i < 5; i++) {
    await gesture.moveBy(by / 5);
    await tester.pump(const Duration(milliseconds: 30));
  }
  await tester.pump(const Duration(milliseconds: 250)); // stick reports every 100 ms
  return gesture;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a camera that sends nothing says so and offers the camera choice', (tester) async {
    final (robot, _) = await _open(tester);
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    expect(find.text('Waiting for camera frames'), findsOneWidget);
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('No picture from /camera/color/image_raw'), findsOneWidget);
    await tester.tap(find.byKey(const Key('camera-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Robot settings'), findsOneWidget);
    robot.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first run suggests a type; omnidirectional drives sideways and stops on release', (tester) async {
    final (robot, camera) = await _open(tester);
    expect(find.text('How does this robot move?'), findsOneWidget);
    expect(find.text('SUGGESTED'), findsOneWidget);
    await tester.tap(find.byKey(const Key('type-holonomic')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    expect(robot.sent, contains(predicate<Map>((m) =>
        m['op'] == 'advertise' && m['topic'] == '/cmd_vel' && m['type'] == 'geometry_msgs/Twist')));
    expect(camera.sent, contains(predicate<Map>((m) =>
        m['op'] == 'subscribe' && m['topic'] == '/camera/color/image_raw')), reason: 'colour, not depth');
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('robot_profile:robot:9090')!)['drive'], 'holonomic');

    final gesture = await _drag(tester, 'stick-left', const Offset(-60, 0)); // push left
    final moving = _published(robot, '/cmd_vel').last['msg'];
    expect(moving['linear']['y'], greaterThan(0.05), reason: 'left = +y in ROS');
    expect(moving['linear']['x'], closeTo(0, 0.02));
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));
    final stopped = _published(robot, '/cmd_vel').last['msg'];
    expect([stopped['linear']['x'], stopped['linear']['y'], stopped['angular']['z']], [0, 0, 0]);
    await tester.pumpWidget(const SizedBox());
  });

  test('analog sticks: dead zone, scaled from its edge, up is forward', () {
    expect(padStick({GamepadAxis.leftStickY: 0.08}).isZero, isTrue, reason: 'a stick resting off-centre');
    final full = padStick({GamepadAxis.leftStickY: 1.0, GamepadAxis.rightStickX: -1.0});
    expect((full.leftY, full.rightX), (-1.0, -1.0));
    expect(padStick({GamepadAxis.leftStickY: 0.56}).leftY, closeTo(-0.5, 0.001));
  });

  testWidgets('a game controller drives with its sticks; B stops and holds until the sticks centre', (tester) async {
    final pad = StreamController<PadEvent>.broadcast();
    addTearDown(pad.close);
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = ros2Topics;
    final camera = FakeConnection();
    addTearDown(robot.close);
    addTearDown(camera.close);
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: 'robot', port: '9090', channel: robot,
        imageConnectionFactory: (_, _) => camera, padEvents: () => pad.stream)));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('type-differential')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    void axis(GamepadAxis a, double v) => pad.add((axis: a, button: null, value: v));
    axis(GamepadAxis.leftStickY, 0.6);
    await tester.pump(const Duration(milliseconds: 250));
    final half = _published(robot, '/cmd_vel').last['msg']['linear']['x'] as num;
    axis(GamepadAxis.leftStickY, 1.0);
    await tester.pump(const Duration(milliseconds: 250));
    final full = _published(robot, '/cmd_vel').last['msg']['linear']['x'] as num;
    expect(half, greaterThan(0.05));
    expect(full, greaterThan(half), reason: 'how far the stick is pushed sets the speed');
    pad.add((axis: null, button: GamepadButton.b, value: 1));
    await tester.pump(const Duration(milliseconds: 150));
    axis(GamepadAxis.leftStickY, 0.9); // still held after B
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], 0);
    axis(GamepadAxis.leftStickY, 0);
    axis(GamepadAxis.leftStickY, -1);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], lessThan(-0.05), reason: 'centred, then back');
    axis(GamepadAxis.leftStickY, 0);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a keyboard or a controller D-pad drives; Space stops at once', (tester) async {
    final (robot, _) = await _open(tester);
    await tester.tap(find.byKey(const Key('type-differential')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], greaterThan(0.05));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['angular']['z'], greaterThan(0.05), reason: 'left = +z');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump(const Duration(milliseconds: 150));
    final stopped = _published(robot, '/cmd_vel').last['msg'];
    expect([stopped['linear']['x'], stopped['angular']['z']], [0, 0]);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], 0, reason: 'still held after STOP: ignored');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyS);
    await tester.pump(const Duration(milliseconds: 250));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], lessThan(-0.05), reason: 'released, then S drives back');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyS);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('namespaced command and odometry topics are discovered by message type', (tester) async {
    final (robot, _) = await _open(tester, topics: {
      'topics': ['/robot1/cmd_vel', '/robot1/odom'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
    });
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    expect(robot.sent, contains(predicate<Map>((m) =>
        m['op'] == 'advertise' && m['topic'] == '/robot1/cmd_vel')));
    expect(robot.sent, contains(predicate<Map>((m) =>
        m['op'] == 'subscribe' && m['topic'] == '/robot1/odom')));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an Ackermann topic suggests car-like control with throttle and steering', (tester) async {
    final (robot, _) = await _open(tester, topics: {
      'topics': ['/drive', '/odom'],
      'types': ['ackermann_msgs/msg/AckermannDriveStamped', 'nav_msgs/msg/Odometry'],
    });
    expect(find.textContaining('Car-like · /drive'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    expect(robot.sent, contains(predicate<Map>((m) =>
        m['op'] == 'advertise' && m['topic'] == '/drive' && m['type'] == 'ackermann_msgs/AckermannDriveStamped')));

    final throttle = await _drag(tester, 'stick-left', const Offset(0, -60));
    final steer = await _drag(tester, 'stick-right', const Offset(60, 0)); // steer right
    final msg = _published(robot, '/drive').last['msg'];
    expect(msg['header']['stamp'], {'sec': 0, 'nanosec': 0});
    expect(msg['drive']['speed'], greaterThan(0.05));
    expect(msg['drive']['steering_angle'], lessThan(-0.05), reason: 'right = negative angle');
    await throttle.up();
    await steer.up();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_published(robot, '/drive').last['msg']['drive']['speed'], 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a large raw camera stream is slowed to what rosbridge can carry, so it stays live', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(
        RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/color/image_raw').toJson())});
    final (_, camera) = await _open(tester);
    final sub = camera.sent.singleWhere((m) => m['op'] == 'subscribe');
    expect(sub['throttle_rate'], 100);
    // 640x360 rgb8: 691200 bytes, ~921600 characters of base64 in rosbridge's JSON.
    camera.events.add({'op': 'publish', 'topic': '/camera/color/image_raw', 'msg': {
      'width': 640, 'height': 360, 'encoding': 'rgb8', 'step': 1920, 'data': 'A' * 921600}});
    await tester.pump();
    await tester.pump();
    final resub = camera.sent.lastWhere((m) => m['op'] == 'subscribe');
    expect(camera.sent, contains(predicate<Map>((m) => m['op'] == 'unsubscribe' && m['id'] == sub['id'])));
    expect(resub['throttle_rate'], closeTo(614, 2), reason: '921600 chars at 1.5 MB/s');
    expect(resub['queue_length'], 1);
    expect(find.byKey(const Key('camera-note')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a manual odometry topic in the profile replaces the discovered one', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(
        RobotProfile.defaults(DriveType.differential).copyWith(odomTopic: '/wheel_state').toJson())});
    final (robot, _) = await _open(tester);
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'unsubscribe' && m['topic'] == '/odom')));
    expect(robot.sent.lastWhere((m) => m['op'] == 'subscribe' && m['topic'] == '/wheel_state'), isNotNull);
    expect(RobotProfile.fromJson(RobotProfile.defaults(DriveType.differential).toJson())!.odomTopic, '',
        reason: 'older saved profiles load with automatic topics');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('driving screen STOP also cancels the navigation started on another screen', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(
      RobotProfile.defaults(DriveType.differential, cameraTopic: '').toJson())});
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection();
    final drive = DriveController(RosClient(robot));
    final nav = NavigationController(RosClient(robot))..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
    final pending = nav.goTo(const Pose2D(1, 0, 0));
    await tester.pumpWidget(MaterialApp(home: ControlScreen(ip: 'robot', port: '9090', channel: robot,
      drive: drive, navigation: nav, imageConnectionFactory: (_, _) => FakeConnection())));
    await tester.pump(); await tester.pump();
    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    expect(await pending, NavStatus.canceled);
    expect(robot.sent.where((m) => m['op'] == 'cancel_action_goal'), isNotEmpty);
    await tester.pumpWidget(const SizedBox());
    drive.dispose(); nav.dispose(); robot.close();
  });

  testWidgets('STOP zeroes motion and a held stick must be released before it drives again', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(
        RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/color/image_raw').toJson())});
    final (robot, _) = await _open(tester);
    expect(find.text('How does this robot move?'), findsNothing, reason: 'stored profile is reused');

    final gesture = await _drag(tester, 'stick-left', const Offset(0, -80));
    final slow = _published(robot, '/cmd_vel').last['msg']['linear']['x'] as num;
    expect(slow, closeTo(0.5 * 0.3, 0.03), reason: 'full stick on the default Slow preset');

    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], 0);
    final count = _published(robot, '/cmd_vel').length;
    await gesture.moveBy(const Offset(0, -5));
    await tester.pump(const Duration(milliseconds: 300));
    expect(_published(robot, '/cmd_vel').length, count, reason: 'latched until released');
    expect(find.text('Release to re-arm'), findsOneWidget, reason: 'only the held stick latches');
    expect(find.text('Turn'), findsOneWidget, reason: 'the untouched right stick stays usable');
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const Key('preset-fast')));
    await tester.pump();
    final again = await _drag(tester, 'stick-left', const Offset(0, -80));
    expect(_published(robot, '/cmd_vel').last['msg']['linear']['x'], closeTo(0.5, 0.05));
    await again.up();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mobile manipulator: arm mode jogs joints, drives the gripper, and STOP holds the arm', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/cmd_vel', '/arm_controller/joint_trajectory', '/joint_states'],
        'types': ['geometry_msgs/msg/Twist', 'trajectory_msgs/msg/JointTrajectory', 'sensor_msgs/msg/JointState'],
      }
      ..serviceResponses['/rosapi/action_servers'] = {'action_servers': ['/gripper_controller/gripper_cmd']};
    addTearDown(robot.close);
    await tester.binding.setSurfaceSize(const Size(900, 420));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: ControlScreen(
      ip: 'robot', port: '9090', channel: robot, imageConnectionFactory: (_, _) => FakeConnection())));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Robot arm · /arm_controller/joint_trajectory'), findsOneWidget);
    await tester.tap(find.byKey(const Key('profile-continue')));
    await tester.pump();
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'advertise'
        && m['topic'] == '/arm_controller/joint_trajectory' && m['type'] == 'trajectory_msgs/JointTrajectory')));
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' && m['topic'] == '/joint_states')));

    robot.events
      ..add({'op': 'publish', 'topic': '/robot_description', 'msg': {'data':
        '<robot><joint name="joint1" type="revolute"><limit lower="-1" upper="1"/></joint>'
        '<joint name="joint2" type="revolute"><limit lower="-1" upper="1"/></joint>'
        '<joint name="gripper_left_joint" type="prismatic"><limit lower="-0.01" upper="0.019"/></joint></robot>'}})
      ..add({'op': 'publish', 'topic': '/joint_states', 'msg': {
        'name': ['wheel_left_joint', 'joint1', 'joint2', 'gripper_left_joint'],
        'position': [3.0, 0.1, -0.2, 0.0]}});
    await tester.pump();
    await tester.tap(find.text('Arm'));
    await tester.pump();
    expect(find.byKey(const Key('stick-left')), findsNothing, reason: 'arm panel replaces the sticks');

    await tester.tap(find.byKey(const Key('jog-joint1-plus')));
    await tester.pump();
    final jog = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/arm_controller/joint_trajectory');
    expect(jog['msg']['joint_names'], ['joint1', 'joint2'], reason: 'wheels and gripper are not arm joints');
    expect(jog['msg']['points'][0]['positions'][0], closeTo(0.1 + 0.0873, 1e-6));
    expect(jog['msg']['points'][0]['positions'][1], closeTo(-0.2, 1e-6));

    bool isArmPublish(Map m) => m['op'] == 'publish' && m['topic'] == '/arm_controller/joint_trajectory';
    final before = robot.sent.where(isArmPublish).length;
    final track = find.byKey(const Key('joint-joint1'));
    await tester.tapAt(tester.getTopLeft(track) + const Offset(20, 18)); // far left of the range
    await tester.pump();
    expect(robot.sent.where(isArmPublish).length, before, reason: 'a tap must not make the arm jump');
    await tester.drag(track, const Offset(40, 0));
    await tester.pump();
    final dragged = robot.sent.lastWhere(isArmPublish)['msg']['points'][0]['positions'][0] as num;
    expect(dragged, greaterThan(0.1), reason: 'dragging right raises the target from the current 0.1 rad');
    expect(dragged, lessThan(0.6), reason: 'relative: a short drag is a small change, not a jump');

    await tester.tap(find.byKey(const Key('gripper-open')));
    await tester.pump();
    final goal = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
    expect(goal['action'], '/gripper_controller/gripper_cmd');
    expect(goal['action_type'], 'control_msgs/action/GripperCommand');
    expect(goal['args']['command']['position'], 0.019);

    await tester.tap(find.byKey(const Key('estop')));
    await tester.pump();
    final hold = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/arm_controller/joint_trajectory');
    expect(hold['msg']['points'][0]['positions'], [0.1, -0.2], reason: 'hold = go to the measured position now');
    expect(robot.sent.last, {'op': 'cancel_action_goal', 'id': goal['id'], 'action': '/gripper_controller/gripper_cmd'});
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('leaving the control screen publishes a stop, unadvertises and closes the camera', (tester) async {
    SharedPreferences.setMockInitialValues({'robot_profile:robot:9090': jsonEncode(
        RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/color/image_raw').toJson())});
    final (robot, camera) = await _open(tester);
    await tester.pumpWidget(const SizedBox());
    final stopped = _published(robot, '/cmd_vel').last['msg'];
    expect(stopped['linear']['x'], 0);
    expect(stopped['angular']['z'], 0);
    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'unadvertise' && m['topic'] == '/cmd_vel')));
    expect(camera.isClosed, isTrue);
    expect(robot.isClosed, isFalse);
  });
}
