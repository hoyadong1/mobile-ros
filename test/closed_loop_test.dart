import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/controllers/odometry.dart';
import 'package:ros_tester/map_geometry.dart' show Pose2D;
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

/// A differential robot that follows the last /cmd_vel and publishes /odom every 20 ms.
/// [efficiency] < 1 models wheel slip (0 = blocked); [publishing] = false stops odometry.
class FakeBase {
  FakeBase(this.robot, {double yaw = 0}) : heading = yaw {
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) => _step(0.02));
  }

  final FakeConnection robot;
  double efficiency = 1;
  bool publishing = true;
  double x = 0, y = 0;
  double heading;
  late final Timer _timer;
  double get yaw => heading;

  void _step(double dt) {
    final cmd = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel',
        orElse: () => const {'msg': {'linear': {'x': 0}, 'angular': {'z': 0}}})['msg'] as Map;
    final v = (cmd['linear']['x'] as num).toDouble() * efficiency;
    final w = (cmd['angular']['z'] as num).toDouble() * efficiency;
    x += v * math.cos(heading) * dt;
    y += v * math.sin(heading) * dt;
    heading = math.atan2(math.sin(heading + w * dt), math.cos(heading + w * dt));
    if (publishing && !robot.events.isClosed) {
      robot.events.add({'op': 'publish', 'topic': '/odom', 'msg': {'pose': {'pose': {
        'position': {'x': x, 'y': y, 'z': 0.0},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': math.sin(heading / 2), 'w': math.cos(heading / 2)}}}}});
    }
  }

  double lastCommandX() => (robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel')
      ['msg']['linear']['x'] as num).toDouble();

  void dispose() => _timer.cancel();
}

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
  late Odometry odometry;
  late FakeBase base;

  Future<void> start({double yaw = 0}) async {
    robot = FakeConnection();
    final ros = RosClient(robot);
    drive = DriveController(ros, period: const Duration(milliseconds: 20))
      ..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2); // 0.5 m/s, 1 rad/s
    nav = NavigationController(ros);
    odometry = Odometry(ros)..listen('/odom', throttleRate: 0);
    base = FakeBase(robot, yaw: yaw);
    await Future<void>.delayed(const Duration(milliseconds: 60)); // first odometry arrives
  }

  tearDown(() {
    base.dispose();
    drive.dispose();
    nav.dispose();
    odometry.dispose();
  });

  Future<SkillResult> run(SkillCall call) async {
    final agent = RobotAgent(drive: drive, nav: nav, odometry: odometry, backend: Scripted([call]));
    final r = await agent.handle('test');
    return r.results.single;
  }

  test('a move stops when odometry says the distance is covered', () async {
    await start();
    final r = await run(const SkillCall('move', {'distance_m': 0.15})); // slow: 0.15 m/s, ~1 s
    expect(r.ok, isTrue, reason: r.message);
    expect(r.message, startsWith('Moved 0.1'));
    expect(r.data['moved_m'] as double, closeTo(0.15, 0.02));
    expect(base.x, closeTo(0.15, 0.03), reason: 'the robot really is there');
    expect(base.lastCommandX(), 0, reason: 'stopped');
  });

  test('wheel slip: the move keeps going until the real distance is covered', () async {
    await start();
    base.efficiency = 0.7; // only 70 % of the commanded speed becomes motion
    final r = await run(const SkillCall('move', {'distance_m': 0.15}));
    expect(r.ok, isTrue, reason: r.message);
    expect(base.x, closeTo(0.15, 0.03), reason: 'a timed move would have stopped at ~0.105 m');
  });

  test('a blocked robot gives up after the time limit and reports how far it got', () async {
    await start();
    base.efficiency = 0;
    final r = await run(const SkillCall('move', {'distance_m': 0.05})); // limit 1.5 x 0.33 s + 1 s
    expect(r.ok, isFalse);
    expect(r.message, contains('did not get there in time'));
    expect(r.data['moved_m'], 0.0);
    expect(base.lastCommandX(), 0);
  });

  test('odometry that stops mid-move stops the robot', () async {
    await start();
    final running = run(const SkillCall('move', {'distance_m': 1.0}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    base.publishing = false;
    final r = await running;
    expect(r.ok, isFalse);
    expect(r.message, contains('odometry stopped arriving'));
    expect(base.x, lessThan(0.3), reason: 'stopped within ~0.5 s of losing odometry, far short of 1 m');
    expect(base.lastCommandX(), 0);
  });

  test('a turn across ±180° counts the angle actually turned', () async {
    await start(yaw: math.pi - 0.2); // turning left crosses +π → -π
    final r = await run(const SkillCall('rotate', {'angle_deg': 45}));
    expect(r.ok, isTrue, reason: r.message);
    expect(r.data['turned_deg'] as int, closeTo(45, 3));
    final turned = math.atan2(math.sin(base.yaw - (math.pi - 0.2)), math.cos(base.yaw - (math.pi - 0.2)));
    expect(turned * 180 / math.pi, closeTo(45, 4));
  });

  test('without odometry the move is timed and says it is an estimate', () async {
    await start();
    final agent = RobotAgent(drive: drive, nav: nav, backend: Scripted([const SkillCall('move', {'distance_m': 0.03})]));
    final r = (await agent.handle('test')).results.single;
    expect(r.ok, isTrue);
    expect(r.message, contains('estimated from time'));
  });

  test('MotionProgress unwraps yaw and measures straight distance', () {
    final p = MotionProgress(const Pose2D(0, 0, 3.0));
    for (final yaw in [3.1, -3.1, -2.9]) {
      p.update(Pose2D(0, 0, yaw));
    }
    expect(p.turned, closeTo((-2.9 + 2 * math.pi) - 3.0, 1e-9));
    p.update(const Pose2D(3, 4, -2.9));
    expect(p.distance, 5);
  });
}
