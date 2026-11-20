import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/learned_tools.dart';
import 'package:ros_tester/agent/learning.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import 'memory_test.dart' show MapStore;
import 'support/fake_ros_connection.dart';

class Scripted extends AgentBackend {
  List<SkillCall> next = const [];
  final asked = <AgentRequest>[];
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async {
    asked.add(request);
    return AgentPlan(calls: next);
  }
}

class FakeModel extends LocalModel {
  int calls = 0;
  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) async {
    calls++;
    return '{"say": "x", "calls": []}';
  }
}

AgentManifest robot({List<LearnedTool> learned = const [], Map<String, String> aliases = const {}}) =>
    AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), canRemember: true,
        learned: learned, aliases: aliases);

const patrol = [SkillCall('rotate', {'angle_deg': 90}), SkillCall('rotate', {'angle_deg': -90})];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the same actions three times become a tool with the person\'s phrasings; new words are added', () async {
    final m = Memory('robot:h', store: MapStore());
    Future<void> did(String said) async {
      await RobotAgent.rememberRun(m, AgentRun(instruction: said, results: const [SkillResult(true, 'ok')]), calls: patrol);
    }
    await did('순찰 돌아');
    await did('한 바퀴 둘러봐');
    expect(m.ofKind(LearnedTool.kind), isEmpty, reason: 'twice is not a habit yet');
    await did('순찰 ㄱㄱ');
    final tool = LearnedTool.fromJson(m.ofKind(LearnedTool.kind).single.data)!;
    expect(tool.name, 'my_usual_1');
    expect(tool.origin, 'habit');
    expect(tool.phrases, ['순찰 돌아', '한 바퀴 둘러봐', '순찰 ㄱㄱ']);
    expect(tool.steps.map((s) => s.args['angle_deg']), [90, -90]);
    await did('순찰 ㄱㄱ!'); // the same words again: not added twice
    expect(LearnedTool.fromJson(m.ofKind(LearnedTool.kind).single.data)!.phrases, hasLength(3));
    // Asked for by the tool's name under new words: those words join it.
    await RobotAgent.rememberRun(m, const AgentRun(instruction: '평소 순찰', results: [SkillResult(true, 'ok')]),
        calls: const [SkillCall('my_usual_1')]);
    expect(LearnedTool.fromJson(m.ofKind(LearnedTool.kind).single.data)!.phrases, contains('평소 순찰'));
    // A failed run or a stop teaches nothing.
    await RobotAgent.rememberRun(m, const AgentRun(instruction: 'x', error: 'blocked'), calls: patrol);
    expect(m.ofKind(LearnedTool.kind), hasLength(1));
  });

  test('the on-device assistant runs a learned tool from its phrasing or "as usual", without the model', () async {
    const tool = LearnedTool(name: 'my_usual_1', description: 'd', steps: patrol, phrases: ['순찰 돌아'], origin: 'habit');
    expect(Learning.directCall('순찰 돌아!', [tool])?.name, 'my_usual_1');
    expect(Learning.directCall('평소처럼 해', [tool])?.name, 'my_usual_1');
    expect(Learning.directCall('앞으로 가', [tool]), isNull);
    final model = FakeModel();
    final plan = await LocalBackend(model).plan(AgentRequest(instruction: '순찰 돌아', manifest: robot(learned: [tool]),
        status: const {}));
    expect(plan.calls.single.name, 'my_usual_1');
    expect(model.calls, 0);
    expect(robot(learned: [tool]).skill('my_usual_1'), isNotNull, reason: 'offered to the online model as a tool');
    expect(plan.calls.single.args, isEmpty);
  });

  test('a tool the online model defines is checked against this robot before it is kept', () {
    final m = robot();
    final good = Learning.define({'name': 'Look Around!', 'description': 'Turn to look around.',
      'steps': '[{"skill":"rotate","angle_deg":"{angle}"},{"skill":"rotate","angle_deg":"-{angle}"}]',
      'parameters': '[{"name":"angle","type":"number","description":"How far","min":10,"max":180}]'}, m);
    expect(good.error, isNull);
    expect(good.tool!.name, 'my_look_around');
    expect(good.tool!.expand({'angle': 45}).map((s) => s.args['angle_deg']), [45, '-45']);
    expect(Learning.define({'name': 'fly', 'description': 'd', 'steps': '[{"skill":"takeoff"}]'}, m).error,
        contains('takeoff'), reason: 'not a skill of this robot');
    expect(Learning.define({'name': 'x', 'description': 'd', 'steps': '[{"skill":"remember","note":"n"}]'}, m).error,
        isNotNull, reason: 'memory skills are not steps');
    expect(Learning.define({'name': 'x', 'description': 'd', 'steps': 'not json'}, m).error, isNotNull);
  });

  test('the person\'s own words are learned by pattern and read plainly before planning', () async {
    String? call(String s) {
      final c = memoryCall(s, robot());
      return c == null ? null : '${c.name} ${c.args.values.join('=')}';
    }
    expect(call('거기라고 하면 부엌이라는 뜻이야'), 'learn_phrase 거기=부엌');
    expect(call('살살은 천천히라는 말이야'), 'learn_phrase 살살=천천히');
    expect(call('when I say "the spot", I mean the kitchen'), 'learn_phrase the spot=the kitchen');
    expect(Learning.rewrite('거기로 가', {'거기': '부엌'}), '부엌로 가');
    expect(robot(aliases: {'거기': '부엌'}).describe(), contains('"거기" means 부엌'));
  });

  test('a learned tool runs its steps through the validator; a bad step stops it', () async {
    final robotLink = FakeConnection();
    final ros = RosClient(robotLink);
    final drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    final mem = Memory('robot:run', store: MapStore());
    await LearnedTool.save(mem, const LearnedTool(name: 'my_check', description: 'Check twice.',
        steps: [SkillCall('get_status'), SkillCall('get_status')]));
    await LearnedTool.save(mem, const LearnedTool(name: 'my_bad', description: 'Bad.',
        steps: [SkillCall('get_status'), SkillCall('strafe', {'distance_m': 1})]));
    final backend = Scripted();
    final agent = RobotAgent(drive: drive, nav: NavigationController(ros), backend: backend, memory: mem,
        userMemory: Memory('user-run', store: MapStore()));
    backend.next = const [SkillCall('my_check')];
    final ok = await agent.handle('check');
    expect(backend.asked.single.manifest.skill('my_check'), isNotNull, reason: 'offered as a tool');
    expect(ok.ok, isTrue, reason: '${ok.error} ${ok.results.map((r) => r.message)}');
    expect(ok.results.single.message, startsWith('Did my_check:'));
    backend.next = const [SkillCall('my_bad')];
    final bad = await agent.handle('bad');
    expect(bad.ok, isFalse);
    expect(bad.results.single.message, contains('strafe'), reason: 'a differential robot cannot strafe');
    agent.dispose();
    robotLink.close();
  });

  test('the same actions spelled differently by a model count as the same', () {
    expect(LearnedTool.signatureOf(const [SkillCall('rotate', {'angle_deg': 30, 'speed': 'slow'})]),
        LearnedTool.signatureOf(const [SkillCall('rotate', {'speed': 'slow', 'angle_deg': 30.0})]));
  });

  test('a learned tool is shared only with robots that can do every step, never over one of the same name', () async {
    const tool = LearnedTool(name: 'my_usual_1', description: 'Look around.', steps: patrol, phrases: ['둘러봐'], origin: 'habit');
    final turner = Memory('robot:turner', store: MapStore()), car = Memory('robot:car', store: MapStore());
    final carTools = AgentManifest.build(profile: RobotProfile.defaults(DriveType.ackermann), canRemember: true);
    final result = await Learning.share(tool, {'turner': (turner, robot()), 'car': (car, carTools)});
    expect(result.shared, ['turner']);
    expect(result.refused['car'], contains('rotate'), reason: 'a car cannot turn in place');
    expect(LearnedTool.fromJson(turner.item(LearnedTool.kind, 'my_usual_1')!.data)!.phrases, ['둘러봐']);
    expect(car.ofKind(LearnedTool.kind), isEmpty);
    final again = await Learning.share(tool, {'turner': (turner, robot())});
    expect(again.refused['turner'], 'already has it');
  });

  test('old work records are folded into one summary line per day', () async {
    var now = DateTime(2026, 11, 16, 9);
    final m = Memory('robot:c', store: MapStore(), clock: () => now = now.add(const Duration(minutes: 30)));
    for (var i = 0; i < 61; i++) {
      await RobotAgent.rememberRun(m, AgentRun(instruction: i.isEven ? '앞으로 20센티 가' : '입구로 가',
          results: i.isEven ? const [SkillResult(true, 'Moved 0.2 m forward.')] : const [],
          error: i.isEven ? null : 'blocked'));
    }
    final episodes = m.ofKind('episode').toList();
    final summaries = [for (final e in episodes) if (e.data?['summary'] == true) e.text];
    expect(episodes.length, lessThan(61));
    expect(summaries, isNotEmpty);
    expect(summaries.first, startsWith('2026-11-16 summary of'));
    expect(summaries.first, contains('"앞으로 20센티 가" x'));
    expect(summaries.first, contains('not done'));
    final recent = RobotPersona.from(m, Memory('user-c', store: MapStore())).recent;
    expect(recent.join(' '), isNotEmpty);
  });

  test('risky phrases are not learned, and "as usual" does not guess between habits', () {
    expect(Learning.unsafePhrase('가', '부엌'), isNotNull, reason: 'one letter would rewrite every request');
    expect(Learning.unsafePhrase('앞으로', '부엌'), isNotNull);
    expect(Learning.unsafePhrase('30', '부엌'), isNotNull);
    expect(Learning.unsafePhrase('거기', '부엌'), isNull);
    const a = LearnedTool(name: 'my_usual_1', description: 'd', steps: patrol, phrases: ['순찰'], origin: 'habit');
    const b = LearnedTool(name: 'my_usual_2', description: 'd', steps: patrol, phrases: ['청소'], origin: 'habit');
    expect(Learning.directCall('평소처럼 해', [a, b]), isNull);
    expect(Learning.directCall('순찰', [a, b])?.name, 'my_usual_1', reason: 'its own words still work');
  });

  test('a memory that cannot be saved does not turn a done command into an error', () async {
    final robotLink = FakeConnection();
    final ros = RosClient(robotLink);
    final drive = DriveController(ros)..configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    final backend = Scripted()..next = const [SkillCall('get_status')];
    final agent = RobotAgent(drive: drive, nav: NavigationController(ros), backend: backend,
        memory: Memory('robot:broken', store: BrokenStore()), userMemory: Memory('user-broken', store: MapStore()));
    final run = await agent.handle('status');
    expect(run.ok, isTrue, reason: '${run.error}');
    expect(agent.memory!.lastError, contains('disk full'));
    expect(agent.memory!.ofKind('episode'), hasLength(1), reason: 'kept for this run');
    agent.dispose();
    robotLink.close();
  });
}

/// Reads nothing and fails to write.
class BrokenStore implements MemoryStore {
  @override
  Future<List<MemoryItem>> read(String scope) async => const [];
  @override
  Future<void> write(String scope, List<MemoryItem> items) async => throw StateError('disk full');
  @override
  Future<void> delete(String scope) async {}
}
