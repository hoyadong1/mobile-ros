// The cloud model for real (through tool/agent_proxy.py), no robot: do everyday requests in Korean and
// English come out as the right tool calls, now that health, position and map tools are offered, and
// does it answer in the person's language?
//   python tool/agent_proxy.py --provider gemini --key-file ~/gemini-key.txt --host 127.0.0.1 --port 8787 --token t1
//   flutter test tool/live_cloud_tools_test.dart --dart-define=PROXY_TOKEN=t1
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/robot_tools.dart';
import 'package:ros_tester/agent/validator.dart';
import 'package:ros_tester/agent/voice.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import '../test/support/fake_ros_connection.dart';

const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');

void main() {
  late AgentManifest manifest;
  setUpAll(() {
    final nav = NavigationController(RosClient(FakeConnection()))..configure(version: RosVersion.ros2,
        navigateAction: '/navigate_to_pose', found: true);
    manifest = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), nav: nav,
        places: const [Place('부엌', 1, 2), Place('charger', 0, 0)],
        abilities: const RobotAbilities(localize: true, savePlace: true, saveMap: true, battery: '/battery_state'));
  });

  var right = 0, total = 0, sameLanguage = 0;
  Future<void> expectSkills(String text, List<String> skills, {Map<String, Object?>? args}) async {
    final backend = CloudBackend(endpoint: Uri.parse(proxy), token: token);
    final watch = Stopwatch()..start();
    final plan = await backend.plan(AgentRequest(instruction: text, manifest: manifest, status: const {}));
    final got = [for (final c in plan.calls) c.name];
    final ok = got.join(',') == skills.join(',') && plan.calls.every((c) => validateCall(c, manifest).ok) &&
        (args == null || args.entries.every((e) => plan.calls.isNotEmpty && plan.calls.first.args[e.key] == e.value));
    final reply = plan.reply ?? '';
    final lang = reply.isEmpty || hasHangul(reply) == hasHangul(text);
    total++;
    if (ok) right++;
    if (lang) sameLanguage++;
    print('${ok ? 'OK ' : 'BAD'}${lang ? '' : ' (language)'} > $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)\n'
        '    calls: ${plan.calls.join(', ')}  reply: $reply');
  }

  test('everyday requests with the new tools', () async {
    await expectSkills('배터리 얼마나 남았어?', ['check_robot']);
    await expectSkills('is anything wrong with the robot?', ['check_robot']);
    await expectSkills('위치 다시 잡아줘', ['find_position']);
    await expectSkills('the robot is lost, find where it is', ['find_position']);
    await expectSkills('여기를 거실로 저장해', ['save_place'], args: {'name': '거실'});
    await expectSkills('remember this spot as front door', ['save_place'], args: {'name': 'front door'});
    await expectSkills('지도 저장해줘', ['save_map']);
    await expectSkills('앞으로 50센티 가', ['move']);
    await expectSkills('turn right 45 degrees', ['rotate']);
    await expectSkills('부엌으로 가줘', ['go_to_place'], args: {'name': '부엌'});
    await expectSkills('지금 상태 알려줘', ['get_status']);
    await expectSkills('하늘로 날아', []);
    print('\n$right / $total right, $sameLanguage / $total replies in the request\'s language');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
