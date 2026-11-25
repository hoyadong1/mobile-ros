import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  late FakeConnection robot;
  late DriveController drive;
  var manual = DriveCommand.stop;
  final base = RobotProfile.defaults(DriveType.differential);

  setUp(() {
    robot = FakeConnection();
    manual = DriveCommand.stop;
    drive = DriveController(RosClient(robot), period: const Duration(milliseconds: 10))
      ..manualInput = (() => manual)
      ..configure(base, RosVersion.ros2);
  });
  tearDown(() => drive.dispose());

  List<double> sentX() => [
    for (final m in robot.sent)
      if (m['op'] == 'publish' && m['topic'] == '/cmd_vel') (m['msg']['linear']['x'] as num).toDouble(),
  ];
  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  test('a TwistStamped command topic (newer Nav2 / ros2_control) gets stamped commands with a zero stamp', () async {
    drive.configure(base, RosVersion.ros2, commandTopicType: 'geometry_msgs/msg/TwistStamped');
    expect(drive.stamped, isTrue);
    expect(robot.sent.lastWhere((m) => m['op'] == 'advertise')['type'], 'geometry_msgs/TwistStamped');
    manual = const DriveCommand(linearX: 0.2, angularZ: 0.5);
    await wait(40);
    final msg = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel')['msg'] as Map;
    expect(msg['twist']['linear']['x'], 0.2);
    expect(msg['twist']['angular']['z'], 0.5);
    expect(msg['header']['stamp'], {'sec': 0, 'nanosec': 0}, reason: 'the robot fills in its own time');
    expect(msg['header']['frame_id'], 'base_link');
    manual = DriveCommand.stop;

    drive.configure(base, RosVersion.ros2, commandTopicType: 'geometry_msgs/msg/Twist');
    expect(drive.stamped, isFalse);
    expect(robot.sent.lastWhere((m) => m['op'] == 'advertise')['type'], 'geometry_msgs/Twist');
    drive.configure(RobotProfile.defaults(DriveType.ackermann), RosVersion.ros2,
        commandTopicType: 'geometry_msgs/msg/TwistStamped');
    expect(drive.stamped, isFalse, reason: 'Ackermann keeps its own message');
  });

  test('motion on the base topic that this app did not send means another driver', () {
    final now = DateTime.now();
    final moving = {'linear': {'x': 0.2, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}};
    final still = {'linear': {'x': 0.0, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': 0.0}};
    drive.observeCommand(still, now: now);
    expect(drive.otherDriving, isFalse, reason: 'a stop is nobody driving');
    drive.observeCommand({'header': {'stamp': {'sec': 5}}, 'twist': still}, now: now);
    expect(drive.otherDriving, isFalse, reason: 'a time stamp is not motion');
    drive.observeCommand(moving, now: now);
    expect(drive.otherDriving, isTrue);
    expect(robot.sent.where((m) => m['op'] == 'subscribe' && m['topic'] == '/cmd_vel'), isNotEmpty,
        reason: 'the base topic is watched');
  });

  test('our own command coming back is not another driver', () async {
    manual = const DriveCommand(linearX: 0.2);
    await wait(40); // the stick is sent
    drive.observeCommand({'linear': {'x': 0.2}, 'angular': {'z': 0.0}});
    expect(drive.otherDriving, isFalse);
  });

  test('advertises the profile command topic', () {
    expect(robot.sent.where((m) => m['op'] == 'advertise').single,
        {'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/Twist'});
  });

  test('agent motion runs for its duration, then one stop', () async {
    final done = drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(milliseconds: 60));
    expect(drive.source, DriveSource.agent);
    expect(drive.agentDriving, isTrue);
    expect(await done, isTrue);
    await wait(40);
    final xs = sentX();
    expect(xs.where((x) => x == 0.2).length, greaterThan(1), reason: 'repeated while moving');
    expect(xs.last, 0);
    expect(xs.where((x) => x == 0).length, 1, reason: 'a single stop, not a stream of zeros');
    expect(drive.source, isNull);
  });

  test('the sticks override the agent and end its motion', () async {
    final done = drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 5));
    manual = const DriveCommand(linearX: -0.1);
    drive.tick();
    expect(await done, isFalse);
    expect(drive.source, DriveSource.manual);
    expect(sentX().last, -0.1);

    // After the person lets go, the agent does not resume.
    manual = DriveCommand.stop;
    drive.tick();
    expect(sentX().last, 0);
    expect(drive.agentDriving, isFalse);
  });

  test('the agent cannot start while a person is driving', () async {
    manual = const DriveCommand(linearX: 0.1);
    drive.tick();
    expect(await drive.driveFor(const DriveCommand(linearX: 0.3), const Duration(seconds: 1)), isFalse);
    expect(sentX(), isNot(contains(0.3)));
  });

  test('stop ends agent motion and publishes zero at once', () async {
    final done = drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 5));
    drive.stop();
    expect(await done, isFalse);
    expect(sentX().last, 0);
    await wait(30);
    expect(sentX().last, 0, reason: 'nothing resumes after stop');
  });

  test('a new agent command replaces the running one', () async {
    final first = drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 5));
    final second = drive.driveFor(const DriveCommand(angularZ: 0.5), const Duration(milliseconds: 30));
    expect(await first, isFalse);
    expect(await second, isTrue);
  });

  test('drones are not arbitrated: no agent motion, no timer, but sendNow publishes', () async {
    drive.configure(RobotProfile.defaults(DriveType.aerial), RosVersion.ros2);
    expect(await drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 1)), isFalse);
    final before = robot.sent.length;
    await wait(30);
    expect(robot.sent.length, before);
    drive.sendNow(const DriveCommand(linearZ: 0.5));
    expect(robot.sent.last['topic'], '/mavros/setpoint_velocity/cmd_vel_unstamped');
  });

  test('a fixed arm (no base) has nothing to drive', () async {
    drive.configure(RobotProfile.defaults(DriveType.none), RosVersion.ros2);
    expect(robot.sent.where((m) => m['op'] == 'unadvertise').single['topic'], '/cmd_vel');
    expect(await drive.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 1)), isFalse);
  });

  test('switching to Ackermann re-advertises with the new type', () {
    drive.configure(RobotProfile.defaults(DriveType.ackermann), RosVersion.ros2);
    expect(robot.sent.where((m) => m['op'] == 'advertise').last,
        {'op': 'advertise', 'topic': '/ackermann_cmd', 'type': 'ackermann_msgs/AckermannDriveStamped'});
    expect(robot.sent.where((m) => m['op'] == 'unadvertise').single['topic'], '/cmd_vel');
  });

  test('dispose stops the base and withdraws the topic', () async {
    final local = DriveController(RosClient(robot))..configure(base, RosVersion.ros2);
    final done = local.driveFor(const DriveCommand(linearX: 0.2), const Duration(seconds: 5));
    local.dispose();
    expect(await done, isFalse);
    expect(sentX().last, 0);
    expect(robot.sent.last, {'op': 'unadvertise', 'topic': '/cmd_vel'});
  });
}
