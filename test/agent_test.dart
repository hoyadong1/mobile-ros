import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/audit_log.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/validator.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/drive_command.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

/// Answers with a fixed plan, or waits for [gate] first.
class ScriptedBackend extends AgentBackend {
  ScriptedBackend(this.calls, {this.reply, this.gate, this.error});
  final List<SkillCall> calls;
  final String? reply;
  final Completer<void>? gate;
  final Object? error;
  AgentRequest? lastRequest;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async {
    lastRequest = request;
    await gate?.future;
    if (error != null) throw error!;
    return AgentPlan(calls: calls, reply: reply);
  }
}

void main() {
  final differential = RobotProfile.defaults(DriveType.differential); // 0.5 m/s, 1 rad/s

  group('manifest', () {
    List<String> names(RobotProfile? p, {NavigationController? nav}) =>
        AgentManifest.build(profile: p, nav: nav).skills.map((s) => s.name).toList();

    test('offers skills by drive type', () {
      expect(names(differential), ['stop', 'get_status', 'move', 'rotate']);
      expect(names(RobotProfile.defaults(DriveType.holonomic)), ['stop', 'get_status', 'move', 'strafe', 'rotate']);
      expect(names(RobotProfile.defaults(DriveType.ackermann)), ['stop', 'get_status', 'move'],
          reason: 'a car cannot turn in place');
      expect(names(RobotProfile.defaults(DriveType.aerial)), ['stop', 'get_status']);
      expect(names(null), ['stop', 'get_status']);
    });

    test('offers navigation only once the controller is configured', () {
      final nav = NavigationController(RosClient(FakeConnection()));
      expect(names(differential, nav: nav), isNot(contains('navigate_to')));
      nav.configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
      expect(names(differential, nav: nav), containsAll(['navigate_to', 'cancel_navigation']));
      nav.dispose();
    });

    test('tool definitions carry JSON schemas with limits', () {
      final move = AgentManifest.build(profile: differential).toTools().firstWhere((t) => t['name'] == 'move');
      final schema = move['input_schema'] as Map;
      expect(schema['required'], ['distance_m']);
      final distance = (schema['properties'] as Map)['distance_m'] as Map;
      expect(distance['maximum'], 2.0);
      expect(((schema['properties'] as Map)['speed'] as Map)['enum'], ['slow', 'normal']);
    });
  });

  group('validator', () {
    final manifest = AgentManifest.build(profile: differential);

    test('clamps numbers to the limit and says so; fills the default speed', () {
      final v = validateCall(const SkillCall('move', {'distance_m': 5}), manifest);
      expect(v.ok, isTrue);
      expect(v.call!.args, {'distance_m': 2.0, 'speed': 'slow'});
      expect(v.notes.single, contains('limited to 2.0'));
    });

    test('accepts numeric strings and case-insensitive enums', () {
      final v = validateCall(const SkillCall('rotate', {'angle_deg': '90', 'speed': 'NORMAL'}), manifest);
      expect(v.call!.args, {'angle_deg': 90.0, 'speed': 'normal'});
    });

    test('rejects unknown skills, unknown or missing arguments, bad values', () {
      expect(validateCall(const SkillCall('fly'), manifest).rejection, contains('not available'));
      expect(validateCall(const SkillCall('strafe', {'distance_m': 1}), manifest).ok, isFalse,
          reason: 'a differential base cannot strafe');
      expect(validateCall(const SkillCall('move', {}), manifest).rejection, contains('needs distance_m'));
      expect(validateCall(const SkillCall('move', {'distance_m': 1, 'topic': '/cmd_vel'}), manifest).rejection,
          contains('does not take topic'));
      expect(validateCall(const SkillCall('move', {'distance_m': 'far'}), manifest).ok, isFalse);
      expect(validateCall(const SkillCall('move', {'distance_m': double.nan}), manifest).ok, isFalse);
      expect(validateCall(const SkillCall('move', {'distance_m': 1, 'speed': 'fast'}), manifest).ok, isFalse,
          reason: 'there is no fast for the agent');
    });

    test('SkillCall.fromJson accepts the common argument keys', () {
      expect(SkillCall.fromJson({'name': 'move', 'input': {'distance_m': 1}})!.args, {'distance_m': 1});
      expect(SkillCall.fromJson({'name': 'stop'})!.args, isEmpty);
      expect(SkillCall.fromJson({'args': {}}), isNull);
    });
  });

  group('agent', () {
    late FakeConnection robot;
    late DriveController drive;
    late NavigationController nav;
    var manual = DriveCommand.stop;

    setUp(() {
      robot = FakeConnection();
      manual = DriveCommand.stop;
      final ros = RosClient(robot);
      drive = DriveController(ros, period: const Duration(milliseconds: 10))
        ..manualInput = (() => manual)
        ..configure(differential, RosVersion.ros2);
      nav = NavigationController(ros)..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
    });
    tearDown(() {
      drive.dispose();
      nav.dispose();
    });

    RobotAgent agent(AgentBackend backend) => RobotAgent(drive: drive, nav: nav, backend: backend);

    test('two panels cannot run automation on the same robot; stop cancels another pending planner', () async {
      final waiting = Completer<void>();
      final first = agent(ScriptedBackend([const SkillCall('move', {'distance_m': 0.03})], gate: waiting));
      final second = agent(ScriptedBackend([const SkillCall('get_status')]));
      final pending = first.handle('move');
      await pumpEventQueue();
      final blocked = await second.handle('status');
      expect(blocked.error, contains('Another instruction or routine'));
      second.stop();
      // STOP releases the gate even if the older model response is still pending.
      final afterStop = await second.handle('status');
      expect(afterStop.error, isNull);
      waiting.complete();
      expect((await pending).error, isNotNull);
      expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel' &&
        (m['msg']['linear']['x'] as num) > 0), isEmpty);
      first.dispose(); second.dispose();
    });

    test('disposing an idle panel does not stop another panels active instruction', () async {
      final waiting = Completer<void>();
      final first = agent(ScriptedBackend([const SkillCall('get_status')], gate: waiting));
      final idle = agent(ScriptedBackend([]));
      final pending = first.handle('status');
      await pumpEventQueue();
      idle.dispose();
      expect(drive.automation.ownedBy(first), isTrue);
      waiting.complete();
      expect((await pending).error, isNull);
      first.dispose();
    });
    List<double> cmdX() => [
      for (final m in robot.sent)
        if (m['op'] == 'publish' && m['topic'] == '/cmd_vel') (m['msg']['linear']['x'] as num).toDouble(),
    ];

    test('plans, validates, drives and logs; the backend sees skills and status', () async {
      final backend = ScriptedBackend([const SkillCall('move', {'distance_m': 0.03})], reply: '앞으로 조금 갈게요.');
      final a = agent(backend);
      final run = await a.handle('앞으로 3센티 가');
      expect(run.ok, isTrue, reason: '${run.results}');
      expect(cmdX(), contains(closeTo(0.15, 1e-9)), reason: 'slow = 30% of 0.5 m/s');
      expect(backend.lastRequest!.manifest.skill('move'), isNotNull);
      expect(backend.lastRequest!.status['motion'], 'stopped');
      expect(a.log.entries.map((e) => e.kind), [
        AuditKind.instruction, AuditKind.plan, AuditKind.call, AuditKind.result]);
    });

    test('a refused call stops the plan; nothing after it runs', () async {
      final run = await agent(ScriptedBackend([
        const SkillCall('teleport', {'x': 1}),
        const SkillCall('move', {'distance_m': 0.03}),
      ])).handle('어딘가로 순간이동');
      expect(run.ok, isFalse);
      expect(run.results.single.message, contains('not available'));
      expect(cmdX(), isEmpty);
    });

    test('the sticks override the agent; the rest of the plan is dropped', () async {
      final a = agent(ScriptedBackend([
        const SkillCall('move', {'distance_m': 1.5}),
        const SkillCall('rotate', {'angle_deg': 90}),
      ]));
      final running = a.handle('앞으로 가다가 돌아');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      manual = const DriveCommand(linearX: -0.1);
      drive.tick();
      final run = await running;
      expect(run.ok, isFalse);
      expect(run.results, hasLength(1));
      expect(run.results.single.message, contains('someone took control'));
    });

    test('a stop word stops at once without the model, even mid-plan', () async {
      final gate = Completer<void>();
      final backend = ScriptedBackend([const SkillCall('move', {'distance_m': 1.0})], gate: gate);
      final a = agent(backend);
      final running = a.handle('앞으로 1미터');
      await Future<void>.delayed(Duration.zero);
      expect(a.busy, isTrue);

      final stopped = await a.handle('멈춰!');
      expect(stopped.ok, isTrue);
      gate.complete();
      final run = await running;
      expect(run.error, 'Interrupted by stop.');
      expect(cmdX().where((x) => x > 0), isEmpty, reason: 'the plan never moved the robot');
      expect(RobotAgent.isStopWord('stop'), isTrue);
      expect(RobotAgent.isStopWord('멈춰서 왼쪽 봐'), isFalse);
    });

    test('a second instruction while busy is refused', () async {
      final gate = Completer<void>();
      final a = agent(ScriptedBackend(const [], gate: gate));
      final first = a.handle('기다려');
      final second = await a.handle('앞으로 가');
      expect(second.error, contains('Still working'));
      gate.complete();
      await first;
    });

    for (final text in ['停止', '止まって！', 'detente', 'arrête-toi', 'dừng lại', 'หยุด', 'توقف', 'berhenti', 'остановись']) {
      test('$text interrupts a pending planner without allowing a late movement plan', () async {
        final gate = Completer<void>();
        final backend = ScriptedBackend([const SkillCall('move', {'distance_m': 1.0})], gate: gate);
        final a = agent(backend);
        final running = a.handle('go forward 1 m');
        await Future<void>.delayed(Duration.zero);
        expect(a.busy, isTrue);
        final stopped = await a.handle(text);
        expect(stopped.ok, isTrue);
        gate.complete();
        final run = await running;
        expect(run.error, 'Interrupted by stop.');
        expect(cmdX().where((x) => x != 0), isEmpty);
      });
    }

    test('a backend failure is reported, nothing moves', () async {
      final run = await agent(ScriptedBackend(const [], error: Exception('offline'))).handle('앞으로');
      expect(run.error, contains('offline'));
      expect(cmdX(), isEmpty);
    });

    test('navigate_to waits for Nav2 and reports arrival', () async {
      final a = agent(ScriptedBackend([const SkillCall('navigate_to', {'x': 1.5, 'y': -2, 'yaw_deg': 90})]));
      final running = a.handle('(1.5, -2)로 가');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final goal = robot.sent.lastWhere((m) => m['op'] == 'send_action_goal');
      expect(goal['args']['pose']['pose']['position'], {'x': 1.5, 'y': -2.0, 'z': 0.0});
      robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 4, 'result': true});
      final run = await running;
      expect(run.ok, isTrue);
      expect(run.results.single.message, 'Arrived at (1.5, -2.0).');
    });

    test('direct driving is refused while navigation runs', () async {
      final a = agent(ScriptedBackend([
        const SkillCall('navigate_to', {'x': 1, 'y': 1}),
      ]));
      unawaited(a.handle('가'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final results = await a.runCalls([const SkillCall('move', {'distance_m': 0.5})]);
      expect(results.single.message, contains('Cancel it before driving'));
      a.stop();
    });

    test('too many steps are refused as a whole', () async {
      final run = await RobotAgent(drive: drive, nav: nav, maxCallsPerPlan: 2,
          backend: ScriptedBackend(List.filled(3, const SkillCall('get_status')))).handle('상태 세 번');
      expect(run.ok, isFalse);
      expect(run.results.single.message, contains('at most 2'));
    });
  });
}
