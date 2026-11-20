import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent_page.dart' show AgentSettings;
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

/// Answers with canned JSON and records what it was asked.
class FakeModel extends LocalModel {
  FakeModel(this.answers);
  final List<String> answers;
  final asked = <({String system, String user, String grammar})>[];
  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) async {
    asked.add((system: system, user: user, grammar: grammar));
    if (answers.isEmpty) throw StateError('no answer');
    return answers.removeAt(0);
  }
}

class CountingCloud extends AgentBackend {
  int plans = 0;
  @override
  String get name => 'cloud';
  @override
  Future<AgentPlan> plan(AgentRequest request) async {
    plans++;
    return const AgentPlan(reply: 'cloud answer');
  }
}

final camera = RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/image_raw/compressed');

AgentRequest request(String text, {AgentManifest? manifest}) =>
    AgentRequest(instruction: text, manifest: manifest ?? AgentManifest.build(profile: camera), status: const {});

void main() {
  missingAbilityTests();
  group('grammar and prompt', () {
    test('every offered skill except look is a choice, with its arguments in order', () {
      final g = skillGrammar(AgentManifest.build(profile: camera));
      expect(g, contains(r'call ::= c-stop | c-get-status | c-move | c-rotate | c-handoff'));
      expect(g, isNot(contains('look')), reason: 'the small model cannot see');
      expect(g, contains(r'c-move ::= "{" ws "\"skill\"" ws ":" ws "\"move\""'
          r' ws "," ws "\"direction\"" ws ":" ws ("\"forward\"" | "\"backward\"")'
          r' ws "," ws "\"distance_m\"" ws ":" ws unum'
          r' (ws "," ws "\"speed\"" ws ":" ws ("\"slow\"" | "\"normal\""))? ws "}"'));
      expect(g, contains(r'("\"left\"" | "\"right\"") ws "," ws "\"angle_deg\"" ws ":" ws unum'),
          reason: 'the small model gives a direction word and a positive amount, never a sign');
      expect(g, contains('calls ::= call (ws "," ws call){0,4}'));
    });

    test('place names, quotes included, are literal choices', () {
      final nav = NavigationController(RosClient(FakeConnection()))
        ..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
      addTearDown(nav.dispose);
      final m = AgentManifest.build(profile: camera, nav: nav,
          places: const [Place('충전기', 0, 0), Place('the "lab"', 1, 1)]);
      final g = skillGrammar(m);
      expect(g, contains(r'("\"충전기\"" | "\"the \\\"lab\\\"\"")'));
      expect(localSystemPrompt(m), contains('User: 충전기(으)로 가줘'));
    });

    test('the prompt lists the actions with their ranges and asks for JSON only', () {
      final p = localSystemPrompt(AgentManifest.build(profile: camera));
      expect(p, contains('- move (direction: forward|backward, distance_m: 0..2 m, speed: slow|normal, optional)'));
      expect(p, contains('- rotate (direction: left|right, angle_deg: 0..360 degrees'));
      expect(p, contains('- handoff:'));
      expect(p, isNot(contains('- look')));
    });
  });

  group('answers', () {
    test('calls, say and handoff are read; unknown parts are left for the validator', () {
      final plan = parseLocalAnswer(
          '{"calls": [{"skill": "move", "direction": "backward", "distance_m": 0.5},'
          ' {"skill": "rotate", "direction": "right", "angle_deg": 90, "speed": "slow"},'
          ' {"skill": "rotate", "direction": "left", "angle_deg": 30}],'
          ' "say": "갈게요."}');
      expect(plan.handoff, isFalse);
      expect(plan.reply, '갈게요.');
      expect(plan.calls.map((c) => '$c'),
          ['move(distance_m: -0.5)', 'rotate(angle_deg: -90, speed: slow)', 'rotate(angle_deg: 30)']);
      expect(plan.calls.first.id, 'local:0');

      final handoff = parseLocalAnswer('{"calls": [{"skill": "handoff"}], "say": ""}');
      expect((handoff.handoff, handoff.calls.length, handoff.reply), (true, 0, null));
      expect(() => parseLocalAnswer('not json'), throwsFormatException);
    });

    test('after get_status the app puts the report into words in the person\'s language (no second model pass)', () async {
      final model = FakeModel(['{"calls": [{"skill": "get_status"}], "say": "확인할게요."}']);
      final backend = LocalBackend(model);
      final plan = await backend.plan(request('지금 상태 알려줘'));
      expect(plan.reply, '지금 상태를 확인할게요.', reason: 'made from the call, not the model\'s say');
      final next = await backend.continueWith([(plan.calls.single,
          const SkillResult(true, 'Not moving.', {'motion': 'stopped', 'navigation': 'idle'}))]);
      expect(next.reply, '멈춰 있고, 이동 목표는 없어요.');
      expect(next.calls, isEmpty);
      expect(model.asked, hasLength(1), reason: 'figures come from the result, not a second generation');
      expect(await backend.continueWith([(const SkillCall('move'), const SkillResult(true, 'Moved.'))]),
          isA<AgentPlan>().having((p) => p.reply, 'reply', isNull), reason: 'motion needs no second pass');
    });
  });

  group('router', () {
    test('a simple command stays on the device', () async {
      final cloud = CountingCloud();
      final router = RouterBackend(local: LocalBackend(FakeModel(
          ['{"calls": [{"skill": "move", "distance_m": 0.3}], "say": "갈게요."}'])), cloud: cloud);
      final plan = await router.plan(request('앞으로 30센티'));
      expect((router.lastRoute, plan.calls.single.name, cloud.plans), (Route.local, 'move', 0));
    });

    test('camera questions go straight to the cloud, without asking the local model', () async {
      final model = FakeModel([]);
      final cloud = CountingCloud();
      final router = RouterBackend(local: LocalBackend(model), cloud: cloud);
      await router.plan(request('앞에 뭐가 보여?'));
      expect((router.lastRoute, cloud.plans, model.asked.length), (Route.cloud, 1, 0));
    });

    test('a handoff, an invalid call or a local failure goes to the cloud', () async {
      for (final answer in [
        '{"calls": [{"skill": "handoff"}], "say": ""}',
        '{"calls": [{"skill": "strafe", "distance_m": 1}], "say": ""}', // not offered on this robot
        'broken',
      ]) {
        final cloud = CountingCloud();
        final router = RouterBackend(local: LocalBackend(FakeModel([answer])), cloud: cloud);
        final plan = await router.plan(request('do something'));
        expect((router.lastRoute, plan.reply, cloud.plans), (Route.cloud, 'cloud answer', 1), reason: answer);
      }
    });

    test('without the cloud (on-device only, or not allowed) nothing uncertain runs', () async {
      final noCloud = RouterBackend(local: LocalBackend(FakeModel([
        '{"calls": [{"skill": "handoff"}], "say": ""}',
        '{"calls": [{"skill": "strafe", "distance_m": 1}], "say": "옆으로 갈게요."}',
      ])));
      final handoff = await noCloud.plan(request('복잡한 일'));
      expect(handoff.calls, isEmpty);
      expect(handoff.reply, contains('cannot handle this request'));
      final invalid = await noCloud.plan(request('옆으로 가'));
      expect(invalid.calls, isEmpty, reason: 'the invalid plan is dropped, not run');

      final cloud = CountingCloud();
      final notAllowed = RouterBackend(local: LocalBackend(FakeModel(['{"calls": [{"skill": "handoff"}], "say": ""}'])),
          cloud: cloud, cloudAllowed: () => false);
      await notAllowed.plan(request('복잡한 일'));
      expect(cloud.plans, 0);
      // A camera question with no cloud: the local model is asked and may answer in words.
      final camOnly = RouterBackend(local: LocalBackend(FakeModel(['{"calls": [{"skill": "handoff"}], "say": ""}'])));
      expect((await camOnly.plan(request('뭐가 보여?'))).calls, isEmpty);
    });

    test('cloud uses are counted', () async {
      var used = 0;
      final router = RouterBackend(cloud: CountingCloud(), onCloudUse: () => used++);
      await router.plan(request('anything'));
      expect(used, 1);
    });

    test('the agent runs a local plan end to end', () async {
      final robot = FakeConnection();
      final ros = RosClient(robot);
      final drive = DriveController(ros)..configure(camera, RosVersion.ros2);
      final nav = NavigationController(ros);
      addTearDown(() {
        drive.dispose();
        nav.dispose();
      });
      final agent = RobotAgent(drive: drive, nav: nav, backend: RouterBackend(local: LocalBackend(FakeModel([
        '{"calls": [{"skill": "get_status"}], "say": "확인할게요."}', '{"say": "멈춰 있어요."}']))));
      final run = await agent.handle('상태?');
      expect(run.ok, isTrue);
      expect(run.replies, ['지금 상태를 확인할게요.', '멈춰 있고, 이동 목표는 없어요.']);
    });
  });

  test('on-device only never offers the online assistant', () {
    const url = 'http://pc:8787/v1/plan';
    expect(const AgentSettings(proxyUrl: url).cloudConfigured, isTrue);
    expect(const AgentSettings(proxyUrl: url, onDeviceOnly: true).cloudConfigured, isFalse);
    expect(jsonEncode(const AgentSettings(onDeviceOnly: true).onDeviceOnly), 'true');
  });
}

// Found on a car-like robot in Gazebo: with only "move" on offer the on-device model turned sideways and
// map requests into forward drives. The app now checks the words before asking it.
void missingAbilityTests() {
  final car = AgentManifest.build(profile: RobotProfile.defaults(DriveType.ackermann, commandTopic: '/ackermann_cmd'));
  final diff = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential));

  test('requests for what the robot lacks never reach the small model', () async {
    for (final text in ['옆으로 50센티 이동해', 'slide to the left 20 cm', '제자리에서 돌아', 'Turn right',
        '지도에서 (2, 1)로 이동해', 'go to (1.5, -2) please']) {
      expect(missingAbility(text, car), isNotNull, reason: text);
    }
    expect(missingAbility('앞으로 1미터 가', car), isNull);
    // No arm skills exist yet, on any robot.
    for (final text in ['팔을 위로 들어올려', '그리퍼 열어', '저 상자 집어', 'raise the arm', 'open the gripper',
        'pick up the box', 'grab it']) {
      expect(missingAbility(text, diff), contains('arm'), reason: text);
    }
    expect(missingAbility('팔십 센티 앞으로 가', diff), isNull, reason: '"팔십" (eighty) is not an arm');
    expect(missingAbility('go to the farm side slowly', car), isNull, reason: '"farm" is not "arm"');
    expect(missingAbility('return to me slowly', car), isNull, reason: '"return" is not "turn"');
    expect(missingAbility('오른쪽으로 90도 돌아', diff), isNull, reason: 'this robot can turn');
    expect(missingAbility('옆으로 가', diff), 'This robot cannot move sideways.');

    final model = FakeModel(['{"say": "ok", "calls": [{"skill": "move", "direction": "forward", "distance_m": 0.5}]}']);
    final cloud = CountingCloud();
    final router = RouterBackend(local: LocalBackend(model), cloud: cloud);
    await router.plan(request('옆으로 50센티 이동해', manifest: car));
    expect((router.lastRoute, model.asked.length, cloud.plans), (Route.cloud, 0, 1));

    final alone = RouterBackend(local: LocalBackend(model));
    final plan = await alone.plan(request('옆으로 50센티 이동해', manifest: car));
    expect(plan.calls, isEmpty);
    expect(plan.reply, '이 로봇은 옆으로 움직일 수 없어요.', reason: 'in the language of the request');
  });
}
