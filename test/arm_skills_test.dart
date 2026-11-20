import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/arm.dart';
import 'package:ros_tester/controllers/arm_controller.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

class FakeModel extends LocalModel {
  FakeModel(this.answers);
  final List<String> answers;
  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) async => answers.removeAt(0);
}

class Scripted extends AgentBackend {
  List<SkillCall> next = const [];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: next);
}

const armConfig = ArmConfig(trajectoryTopic: '/arm_controller/joint_trajectory', gripperAction: '/gripper_controller/gripper_cmd');

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late FakeConnection robot;
  late RosClient ros;
  late DriveController drive;
  late NavigationController nav;
  late ArmController arm;
  late ArmPoseBook poses;
  late Scripted backend;
  late RobotAgent agent;

  void jointStates(Map<String, double> joints) => robot.events.add({'op': 'publish', 'topic': '/joint_states',
    'msg': {'name': joints.keys.toList(), 'position': joints.values.toList()}});

  setUp(() async {
    robot = FakeConnection();
    ros = RosClient(robot);
    drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    nav = NavigationController(ros);
    arm = ArmController(ros)..configure(armConfig, RosVersion.ros2);
    poses = ArmPoseBook('robot:9090');
    await poses.load();
    backend = Scripted();
    agent = RobotAgent(drive: drive, nav: nav, backend: backend, arm: arm, armPoses: poses);
  });
  tearDown(() {
    agent.dispose();
    arm.dispose();
    drive.dispose();
    nav.dispose();
  });

  test('arm skills are offered only for a configured arm, with saved postures as the only choices', () async {
    final noArm = RobotAgent(drive: drive, nav: nav, backend: backend);
    expect(noArm.manifest().skill('arm_to_pose'), isNull);
    noArm.dispose();

    expect(agent.manifest().skill('arm_to_pose')!.params.single.values, ['home']);
    expect(agent.manifest().skill('gripper')!.params.single.values, ['open', 'close']);
    await poses.save(const ArmPose('carry', {'joint1': 0.5, 'joint2': -0.3}));
    expect(agent.manifest().skill('arm_to_pose')!.params.single.values, ['carry', 'home']);
    expect(agent.manifest().describe(), contains('saved postures: carry, home'));
    final reloaded = ArmPoseBook('robot:9090');
    await reloaded.load();
    expect(reloaded.find('CARRY')!.joints, {'joint1': 0.5, 'joint2': -0.3});
  });

  test('a model cannot send the arm to joint values it makes up', () async {
    backend.next = [const SkillCall('arm_to_pose', {'name': 'wave'})];
    final r = await agent.handle('wave');
    expect(r.ok, isFalse);
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == armConfig.trajectoryTopic), isEmpty);
  });

  test('arm_to_pose publishes one trajectory and succeeds when the joints arrive', () async {
    await poses.save(const ArmPose('carry', {'joint1': 0.5, 'joint2': -0.3}));
    jointStates({'joint1': 0.0, 'joint2': 0.0, 'gripper_left_joint': 0.0, 'wheel_left_joint': 1.0});
    await Future<void>.delayed(Duration.zero);
    backend.next = [const SkillCall('arm_to_pose', {'name': 'carry'})];
    final running = agent.handle('carry');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final sent = robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == armConfig.trajectoryTopic).toList();
    expect(sent, hasLength(1));
    expect(sent.single['msg']['joint_names'], ['joint1', 'joint2'], reason: 'not wheels or gripper fingers');
    expect(sent.single['msg']['points'][0]['positions'], [0.5, -0.3]);
    jointStates({'joint1': 0.49, 'joint2': -0.31, 'gripper_left_joint': 0.0, 'wheel_left_joint': 1.0});
    final r = await running;
    expect(r.ok, isTrue, reason: '${r.results}');
    expect(r.results.single.message, 'The arm is at "carry".');
  });

  test('stop holds the arm where it is and ends a running move', () async {
    jointStates({'joint1': 0.2, 'joint2': 0.0});
    await Future<void>.delayed(Duration.zero);
    backend.next = [const SkillCall('arm_to_pose', {'name': 'home'})];
    final running = agent.handle('home');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    jointStates({'joint1': 0.1, 'joint2': 0.0});
    await Future<void>.delayed(Duration.zero);
    await agent.handle('멈춰');
    final r = await running;
    expect(r.ok, isFalse);
    final last = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == armConfig.trajectoryTopic);
    expect(last['msg']['points'][0]['positions'], [0.1, 0.0], reason: 'held at the measured position');
  });

  test('the on-device model may only use a posture the person named; replies are real sentences', () async {
    await poses.save(const ArmPose('carry', {'joint1': 0.5}));
    final m = agent.manifest();
    LocalPlan plan(String calls) => parseLocalAnswer('{"say": "", "calls": [$calls]}');
    const home = '{"skill": "arm_to_pose", "name": "home"}';
    expect(keepNamesAsSaid(plan(home), '팔을 위로 쭉 뻗어', m), isNull, reason: 'found on the arm simulator');
    expect(keepNamesAsSaid(plan(home), 'put the arm back home', m), isNotNull);
    expect(keepNamesAsSaid(plan(home), '팔 원래대로 해', m), isNotNull);
    expect(keepNamesAsSaid(plan('{"skill": "arm_to_pose", "name": "carry"}'), '팔을 carry 자세로', m), isNotNull);

    final backend = LocalBackend(FakeModel(['{"say": "arm_to_pose 할게요", "calls": [$home]}',
      '{"say": "x", "calls": [{"skill": "arm_to_pose", "name": "carry"}, {"skill": "gripper", "action": "open"}]}']));
    final refused = await backend.plan(AgentRequest(instruction: '팔을 위로 쭉 뻗어', manifest: m, status: const {}));
    expect((refused.calls.length, refused.handoff), (0, true));
    expect(refused.reply, contains('carry'));
    final ok = await backend.plan(AgentRequest(instruction: '팔을 carry 자세로 하고 그리퍼 열어', manifest: m, status: const {}));
    expect(ok.reply, '팔을 carry 자세로 움직이고, 그리퍼를 열게요.');
  });

  test('the on-device model is no longer kept away from the arm once arm skills exist', () {
    final m = agent.manifest();
    expect(missingAbility('팔을 home 자세로', m), isNull);
    expect(missingAbility('그리퍼 닫아', m), isNull);
    expect(localSystemPrompt(m), contains('"skill": "gripper", "action": "close"'));
  });
}
