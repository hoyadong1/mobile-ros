import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/fleet_agent.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/routines.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_ros_connection.dart';

class _Plan extends AgentBackend {
  _Plan(this.calls);
  final List<SkillCall> calls;
  @override
  String get name => 'test';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls);
}

void main() {
  test('fleet skills require a known robot and run on both sessions', () async {
    SharedPreferences.setMockInitialValues({});
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
    };
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    final agent = FleetAgent(sessions, _Plan([
      const SkillCall('get_status', {'robot': 'robot1'}),
      const SkillCall('get_status', {'robot': 'robot2'}),
    ]));
    final manifest = await agent.manifest();
    expect(manifest.skill('get_status')!.param('robot')!.values, ['robot1', 'robot2']);
    final result = await agent.handle('Status of both robots');
    expect(result.ok, isTrue);
    expect(result.results, hasLength(2));
    expect(result.results[0].message, startsWith('robot1:'));
    expect(result.results[1].message, startsWith('robot2:'));

    final rejected = await agent.runCalls([const SkillCall('get_status', {'robot': 'robot3'})], manifest);
    expect(rejected.single.$2.ok, isFalse);
    agent.dispose();
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });

  test('navigation goals for different robots start together', () async {
    SharedPreferences.setMockInitialValues({});
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot1/goal_pose',
        '/robot2/cmd_vel', '/robot2/odom', '/robot2/goal_pose'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/PoseStamped', 'geometry_msgs/msg/Twist',
        'nav_msgs/msg/Odometry', 'geometry_msgs/msg/PoseStamped'],
    };
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    final agent = FleetAgent(sessions, _Plan([
      const SkillCall('navigate_to', {'robot': 'robot1', 'x': 1, 'y': 0}),
      const SkillCall('navigate_to', {'robot': 'robot2', 'x': 0, 'y': 1}),
    ]));
    final running = agent.handle('Send both robots');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(connection.sent.where((m) => m['op'] == 'publish').map((m) => m['topic']),
      containsAll(['/robot1/goal_pose', '/robot2/goal_pose']));
    final stopped = await agent.handle('停止');
    expect(stopped.results.single.message, 'All robots stopped.');
    expect((await running).error, 'Interrupted by stop.');
    agent.dispose();
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });

  test('an empty model answer is not shown as a reply', () async {
    SharedPreferences.setMockInitialValues({});
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot2/cmd_vel', '/robot2/odom'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
    };
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    final agent = FleetAgent(sessions, _Answer());
    final run = await agent.handle('status of robot1');
    expect(run.replies, ['robot1 is idle.']);
    agent.dispose();
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });
  test('fleet routines: offered without a robot, run each robot together, refused whole when a robot is wrong', () async {
    SharedPreferences.setMockInitialValues({});
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot1/goal_pose',
        '/robot2/cmd_vel', '/robot2/odom', '/robot2/goal_pose'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'geometry_msgs/msg/PoseStamped',
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'geometry_msgs/msg/PoseStamped'],
    };
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    final book = FleetAgent.bookFor(sessions.first);
    await book.load();
    await book.save(Routine(id: 'a', name: 'close up', steps: const [
      RoutineStep.call(SkillCall('navigate_to', {'robot': 'robot1', 'x': 1, 'y': 0})),
      RoutineStep.call(SkillCall('navigate_to', {'robot': 'robot2', 'x': 0, 'y': 1})),
    ]));
    await book.save(Routine(id: 'b', name: 'broken', steps: const [
      RoutineStep.call(SkillCall('navigate_to', {'robot': 'robot1', 'x': 1, 'y': 0})),
      RoutineStep.call(SkillCall('navigate_to', {'robot': 'robot7', 'x': 0, 'y': 1})),
    ]));
    final agent = FleetAgent(sessions, RouterBackend(), routines: book); // no model: routines still run
    final m = await agent.manifest();
    expect(m.skill('run_routine')!.param('name')!.values, ['close up', 'broken']);
    expect(m.skill('run_routine')!.param('robot'), isNull, reason: 'its steps name their robots');
    expect(m.skill('save_routine')!.param('robot'), isNull);
    expect(FleetAgent.bookFor(sessions.last).robot, book.robot, reason: 'one book per connection');

    final refused = await agent.runRoutine(book.find('broken')!);
    expect(refused.ok, isFalse);
    expect(connection.sent.where((s) => s['op'] == 'publish'), isEmpty, reason: 'checked before anyone moves');

    final running = agent.runRoutine(book.find('close up')!);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(connection.sent.where((s) => s['op'] == 'publish').map((s) => s['topic']),
      containsAll(['/robot1/goal_pose', '/robot2/goal_pose']), reason: 'both robots set off together');
    agent.stop();
    expect((await running).error, 'Interrupted by stop.');

    // Nothing was done in an instruction yet: nothing to save.
    final empty = await agent.runCalls([const SkillCall('save_routine', {'name': 'x'})], m);
    expect(empty.single.$2.ok, isFalse);
    agent.dispose();
    book.dispose();
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });
}

/// A model that calls a tool without saying anything, then answers in words.
class _Answer extends AgentBackend {
  @override
  String get name => 'test';
  @override
  Future<AgentPlan> plan(AgentRequest request) async =>
      const AgentPlan(reply: ' ', calls: [SkillCall('get_status', {'robot': 'robot1'})]);
  @override
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) async =>
      const AgentPlan(reply: 'robot1 is idle.');
}
