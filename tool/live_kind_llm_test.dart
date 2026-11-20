// ignore_for_file: avoid_print
// Natural-language instructions on each kind of robot with real models: does the assistant use only
// what this robot can do, and say so when asked for something it cannot? Run through
// scripts/dev-env/sim_live_test.sh with the matching simulation (see tool/live_kind_test.dart) and
//   --dart-define=KIND=car|omni|arm|diff
//   --dart-define=BACKEND=cloud   (proxy on PROXY with PROXY_TOKEN)   or
//   --dart-define=BACKEND=local --dart-define=LOCAL=<model.gguf>      (on-device model only, no cloud)
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/controllers/arm_controller.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
const kind = String.fromEnvironment('KIND', defaultValue: 'diff');
const backendName = String.fromEnvironment('BACKEND', defaultValue: 'cloud');
const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');
const localModel = String.fromEnvironment('LOCAL');
/// A reachable map point for this simulation, as "x, y" (e.g. "-7.0, 0.5"); empty skips navigation.
const navGoal = String.fromEnvironment('NAV_GOAL');

void main() {
  late RosConnection connection;
  late RobotSession session;
  late RobotAgent agent;

  setUpAll(() async {
    // ignore: invalid_use_of_visible_for_testing_member -- a manual test run outside test/
    SharedPreferences.setMockInitialValues({});
    connection = RosConnection(host, port);
    await connection.ready;
    session = RobotSession(connection: connection, ip: host, port: port);
    await session.prepare();
    if (kind == 'omni') {
      // What the person picks in the robot settings (a Twist topic alone cannot tell omni from differential).
      session.drive.configure(session.drive.profile!.copyWith(drive: DriveType.holonomic),
          (await session.capabilities()).rosVersion);
    }
    final AgentBackend backend = backendName == 'local'
        ? RouterBackend(local: LocalBackend(NativeLlm(localModel)))
        : CloudBackend(endpoint: Uri.parse(proxy), token: token);
    if (kind == 'arm') {
      // What a person would do first on the control screen: save a posture under a name.
      await session.armPoses.save(const ArmPose('carry', {'joint1': 0.5, 'joint2': -0.6, 'joint3': 0.3, 'joint4': 0.6}));
    }
    agent = RobotAgent.forSession(session, backend);
    print('  $kind / $backendName; skills: ${agent.manifest().skills.map((s) => s.name).join(', ')}');
  });

  tearDownAll(() {
    agent.stop();
    session.dispose();
    connection.close();
  });

  /// Says [instruction]; returns the calls that ran ok, the replies, metres moved and degrees turned.
  Future<({List<String> calls, String reply, double moved, double left, double turned, AgentRun run})> say(
      String instruction) async {
    await session.odometry.waitFresh();
    final a = session.odometry.pose!;
    final before = agent.log.entries.length;
    final watch = Stopwatch()..start();
    final run = await agent.handle(instruction);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final b = session.odometry.pose!;
    final entries = agent.log.entries.skip(before).toList();
    final calls = [for (final e in entries) if (e.kind.name == 'call') e.text];
    final rejected = [for (final e in entries) if (e.kind.name == 'rejected') e.text];
    final moved = math.sqrt(math.pow(b.x - a.x, 2) + math.pow(b.y - a.y, 2));
    final left = -(b.x - a.x) * math.sin(a.yaw) + (b.y - a.y) * math.cos(a.yaw);
    final turned = math.atan2(math.sin(b.yaw - a.yaw), math.cos(b.yaw - a.yaw)) * 180 / math.pi;
    print('> $instruction  (${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s)');
    print('  calls: ${calls.isEmpty ? '(none)' : calls.join(' | ')}${rejected.isEmpty ? '' : '  REJECTED: ${rejected.join(' | ')}'}');
    print('  reply: ${run.replies.join(' / ')}${run.error == null ? '' : '  ERROR: ${run.error}'}');
    print('  odometry: ${moved.toStringAsFixed(2)} m (left ${left.toStringAsFixed(2)}), ${turned.toStringAsFixed(0)}°');
    return (calls: calls, reply: run.replies.join(' '), moved: moved, left: left, turned: turned, run: run);
  }

  test('instructions in words on a $kind robot ($backendName)', () async {
    switch (kind) {
      case 'car':
        final go = await say('앞으로 1미터 가');
        expect(go.moved, closeTo(1.0, 0.3));
        final spin = await say('제자리에서 왼쪽으로 90도 돌아');
        expect(spin.calls.where((c) => c.startsWith('rotate')), isEmpty, reason: 'a car cannot turn in place');
        expect(spin.moved, lessThan(0.15), reason: 'it explains instead of improvising a manoeuvre');
        final back = await say('go back half a meter');
        expect(back.moved, closeTo(0.5, 0.25));
        final nav = await say('지도에서 (2, 1)로 이동해');
        expect(nav.calls.where((c) => c.startsWith('navigate')), isEmpty, reason: 'no map, no navigation');
        expect(nav.moved, lessThan(0.15), reason: 'and it is not replaced by a drive straight ahead');
      case 'omni':
        final side = await say('왼쪽으로 30센티 옆으로 이동해 (회전하지 말고)');
        expect(side.left, closeTo(0.3, 0.08));
        expect(side.turned.abs(), lessThan(8));
        final right = await say('slide 20 cm to the right');
        expect(right.left, closeTo(-0.2, 0.08));
        final turn = await say('오른쪽으로 90도 돌아');
        expect(turn.turned, closeTo(-90, 10));
      case 'arm':
        final carry = session.armPoses.find('carry')!.joints;
        final toCarry = await say('팔을 carry 자세로 움직여');
        print('  arm error after carry: ${(session.arm.errorTo(carry) * 57.3).toStringAsFixed(1)}°');
        expect(toCarry.calls.where((c) => c.startsWith('arm_to_pose')), isNotEmpty);
        expect(toCarry.moved, lessThan(0.02), reason: 'the base stays put');
        expect(session.arm.errorTo(carry), lessThan(0.06));
        final open = await say('그리퍼 열어');
        expect(open.calls.where((c) => c.startsWith('gripper(action: open')), isNotEmpty);
        expect(open.run.ok, isTrue, reason: open.reply);
        final home = await say('put the arm back home');
        expect(home.calls.where((c) => c.startsWith('arm_to_pose(name: home')), isNotEmpty);
        print('  arm error after home: ${(session.arm.errorTo({for (final j in carry.keys) j: 0.0}) * 57.3).toStringAsFixed(1)}°');
        expect(session.arm.errorTo({for (final j in carry.keys) j: 0.0}), lessThan(0.06));
        final made = await say('팔을 위로 쭉 뻗어');
        expect(made.calls.where((c) => c.startsWith('move') || c.startsWith('rotate')), isEmpty,
            reason: 'driving is not moving the arm, and there is no saved posture for this');
        expect(made.calls.where((c) => c.startsWith('arm_to_pose')), isEmpty,
            reason: 'no saved posture is called that: not replaced by another one');
        final drive = await say('앞으로 20센티 가');
        expect(drive.moved, closeTo(0.2, 0.06));
        if (backendName == 'cloud') {
          final see = await say('카메라로 앞에 뭐가 보이는지 알려줘');
          expect(see.calls.where((c) => c.startsWith('look')), isNotEmpty);
          expect(see.reply, isNotEmpty);
        }
      default:
        final go = await say('앞으로 30센티 가고 오른쪽으로 90도 돌아');
        expect(go.moved, closeTo(0.3, 0.06));
        expect(go.turned, closeTo(-90, 10));
        final side = await say('옆으로 30센티 게걸음으로 이동해');
        expect(side.calls.where((c) => c.startsWith('strafe')), isEmpty);
        expect(side.moved, lessThan(0.1), reason: 'not replaced by another motion');
        if (backendName == 'cloud' && agent.manifest().skill('look') != null) {
          final see = await say('카메라로 앞에 뭐가 보이는지 알려줘');
          expect(see.calls.where((c) => c.startsWith('look')), isNotEmpty);
          expect(see.reply, isNotEmpty);
        }
        if (navGoal.isNotEmpty && agent.manifest().skill('navigate_to') != null) {
          final nav = await say('지도에서 ($navGoal) 위치로 이동해');
          expect(nav.calls.where((c) => c.startsWith('navigate_to')), isNotEmpty);
          expect(nav.run.ok, isTrue);
        }
    }
  }, timeout: const Timeout(Duration(minutes: 6)));
}
