// The on-device model for real with the health, position and map skills (check_robot, find_position,
// save_place, save_map): do everyday requests in Korean and English come out as the right skill, and
// do motion requests still come out as motion now that more skills are offered?
//   MOBILE_ROS_LLM_MODEL=<path>/Qwen3.5-2B-Q4_K_M.gguf flutter test tool/live_local_tools_test.dart
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/robot_tools.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/validator.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import '../test/support/fake_ros_connection.dart';

void main() {
  late NativeLlm llm;
  late LocalBackend backend;
  late AgentManifest manifest;

  setUpAll(() async {
    final path = await LocalModelFile.path();
    expect(NativeLlm.available, isTrue, reason: '${NativeLlm.loadError}');
    llm = NativeLlm(path!);
    backend = LocalBackend(llm);
    final nav = NavigationController(RosClient(FakeConnection()))..configure(version: RosVersion.ros2,
        navigateAction: '/navigate_to_pose', found: true);
    manifest = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), nav: nav,
        places: const [Place('부엌', 1, 2), Place('charger', 0, 0)],
        abilities: const RobotAbilities(localize: true, savePlace: true, saveMap: true, battery: '/battery_state'));
  });
  tearDownAll(() => llm.dispose());

  var right = 0, total = 0;
  Future<void> expectSkills(String text, List<String> skills, {Map<String, Object?>? args}) async {
    final watch = Stopwatch()..start();
    final plan = await backend.plan(AgentRequest(instruction: text, manifest: manifest, status: const {}));
    final got = [for (final c in plan.calls) c.name];
    final ok = got.join(',') == skills.join(',') && plan.calls.every((c) => validateCall(c, manifest).ok) &&
        (args == null || args.entries.every((e) => plan.calls.isNotEmpty && plan.calls.first.args[e.key] == e.value));
    total++;
    if (ok) right++;
    print('${ok ? 'OK ' : 'BAD'} > $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)\n'
        '    calls: ${plan.calls.join(', ')}${plan.handoff ? ' handoff' : ''}  say: ${plan.reply}');
  }

  test('health, position and map requests', () async {
    await expectSkills('배터리 얼마나 남았어?', ['check_robot']);
    await expectSkills('로봇 어디 문제 있어?', ['check_robot']);
    await expectSkills('how much battery is left?', ['check_robot']);
    await expectSkills('위치 다시 잡아줘', ['find_position']);
    await expectSkills('the robot is lost, find where it is', ['find_position']);
    await expectSkills('여기를 거실로 저장해', ['save_place'], args: {'name': '거실'});
    await expectSkills('remember this spot as front door', ['save_place'], args: {'name': 'front door'});
    await expectSkills('지도 저장해줘', ['save_map']);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('motion still comes out as motion with the new skills offered', () async {
    await expectSkills('앞으로 50센티 가', ['move']);
    await expectSkills('왼쪽으로 90도 돌아', ['rotate']);
    await expectSkills('부엌으로 가줘', ['go_to_place'], args: {'name': '부엌'});
    await expectSkills('지금 상태 알려줘', ['get_status']);
    print('\n$right / $total right');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('a check_robot report is answered in a sentence made from its figures', () async {
    await backend.plan(AgentRequest(instruction: '배터리 얼마나 남았어?', manifest: manifest, status: const {}));
    final answer = await backend.continueWith([(const SkillCall('check_robot'),
        const SkillResult(true, 'Battery: 18 % (Battery low). No warnings or errors in the last 10 minutes.',
            {'battery': '18 %', 'battery_warning': 'Battery low', 'errors': <String>[], 'warnings': <String>[]}))]);
    print('answer: ${answer.reply}');
    expect(answer.reply, isNotNull);
    expect(answer.reply, contains('18'));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
