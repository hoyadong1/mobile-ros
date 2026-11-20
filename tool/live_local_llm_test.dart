// The on-device model for real: llama.cpp (native/llm/prebuilt/windows-x64/mobileros_llm.dll) with the
// downloaded GGUF, no robot. Checks the grammar is accepted, answers parse, and simple commands come out
// as the right skills; prints the time per instruction.
//   MOBILE_ROS_LLM_MODEL=~/ros-ai-lab/models/Qwen3.5-2B-Q4_K_M.gguf flutter test tool/live_local_llm_test.dart
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/validator.dart';
import 'package:ros_tester/robot_profile.dart';

void main() {
  late NativeLlm llm;
  late LocalBackend backend;
  final manifest = AgentManifest.build(
      profile: RobotProfile.defaults(DriveType.differential, cameraTopic: '/camera/image_raw/compressed'));

  setUpAll(() async {
    final path = await LocalModelFile.path();
    expect(NativeLlm.available, isTrue, reason: '${NativeLlm.loadError}');
    llm = NativeLlm(path!);
    backend = LocalBackend(llm);
  });
  tearDownAll(() => llm.dispose());

  Future<LocalPlan> ask(String text) async {
    final watch = Stopwatch()..start();
    final plan = await backend.plan(AgentRequest(instruction: text, manifest: manifest, status: const {}));
    print('> $text  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)\n'
        '  calls: ${plan.calls.join(', ')}${plan.handoff ? ' handoff' : ''}  say: ${plan.reply}');
    for (final c in plan.calls) {
      expect(validateCall(c, manifest).ok, isTrue, reason: '$c');
    }
    return plan;
  }

  test('simple motion', () async {
    final a = await ask('앞으로 50센티 가');
    expect(a.calls.single.name, 'move');
    expect(a.calls.single.args['distance_m'], closeTo(0.5, 1e-9));
    final b = await ask('왼쪽으로 90도 돌고 뒤로 30센티 가');
    expect(b.calls.map((c) => c.name), ['rotate', 'move']);
    expect(b.calls.first.args['angle_deg'], 90);
    expect(b.calls.last.args['distance_m'], closeTo(-0.3, 1e-9));
    final c = await ask('turn right');
    expect(c.calls.single.args['angle_deg'], lessThan(0));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('what this robot lacks is refused, not replaced by another action', () async {
    // A car without a map: only move is offered.
    final car = AgentManifest.build(profile: RobotProfile.defaults(DriveType.ackermann, commandTopic: '/ackermann_cmd'));
    expect(car.skills.map((s) => s.name), isNot(contains('rotate')));
    Future<LocalPlan> askCar(String text) async {
      final plan = await backend.plan(AgentRequest(instruction: text, manifest: car, status: const {}));
      print('> [car] $text\n  calls: ${plan.calls.join(', ')}${plan.handoff ? ' handoff' : ''}  say: ${plan.reply}');
      return plan;
    }
    for (final text in ['지도에서 (2, 1)로 이동해', '제자리에서 왼쪽으로 90도 돌아', 'go to x 3 y 1 on the map',
        '옆으로 50센티 이동해']) {
      expect((await askCar(text)).calls, isEmpty, reason: text);
    }
    expect((await askCar('앞으로 1미터 가')).calls.single.args['distance_m'], 1);
    // The differential robot of the other tests has no map either, and cannot move sideways.
    expect((await ask('지도에서 (1.5, 0.5)로 가')).calls, isEmpty);
    expect((await ask('왼쪽으로 30센티 게걸음')).calls, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('status, impossible, and what needs the bigger model', () async {
    expect((await ask('지금 상태 알려줘')).calls.single.name, 'get_status');
    final fly = await ask('하늘로 날아올라');
    expect(fly.calls, isEmpty);
    expect(fly.handoff, isFalse);
    expect((await ask('앞에 뭐가 보이는지 말해줘')).handoff, isTrue);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
