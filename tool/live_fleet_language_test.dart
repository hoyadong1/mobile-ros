// ignore_for_file: avoid_print -- the printed table is the point of this manual survey
// Fleet sentences in the languages of the largest robot markets (same order as
// tool/live_language_matrix_test.dart), through the fleet's real routing: the on-device fleet planner
// (split by robot, then the one-robot planner) and the online model. Two robots, no robot hardware.
//   flutter test tool/live_fleet_language_test.dart [--dart-define=PROXY_TOKEN=<token>] \
//       [--dart-define=LOCAL=<model.gguf>] [--dart-define=ONLY=ja,de] [--dart-define=CLOUD_GAP_MS=4500]
// Wrong answers are reported; it fails only when a robot that was not asked moves, or something moves
// for a robot that is not in the fleet.
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/cloud_backend.dart';
import 'package:ros_tester/agent/local/fleet_local_backend.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import '../test/support/fake_ros_connection.dart';

const proxy = String.fromEnvironment('PROXY', defaultValue: 'http://127.0.0.1:8787/v1/plan');
const token = String.fromEnvironment('PROXY_TOKEN');
const localModel = String.fromEnvironment('LOCAL');
const only = String.fromEnvironment('ONLY');
const gapMs = int.fromEnvironment('CLOUD_GAP_MS', defaultValue: 4500);

/// P robot1 forward 50 cm, robot2 right 90° · Q all robots back 30 cm · R robot1 kitchen, robot2 charging dock
/// S all robots stop · T robot3 (not in the fleet) forward 50 cm
const rows = <(String, List<String>)>[
  ('zh', ['robot1向前走50厘米，robot2向右转90度', '所有机器人后退30厘米', 'robot1去厨房，robot2去充电座', '所有机器人停下', 'robot3向前走50厘米']),
  ('ja', ['robot1は50センチ前に進んで、robot2は右に90度回って', '全部のロボット30センチ下がって',
    'robot1はキッチンに行って、robot2は充電ドックに行って', '全部のロボット止まって', 'robot3は50センチ前に進んで']),
  ('en', ['robot1 go forward 50 cm, robot2 turn right 90 degrees', 'all robots back up 30 cm',
    'robot1 go to the kitchen, robot2 go to the charging dock', 'all robots stop', 'robot3 go forward 50 cm']),
  ('ko', ['robot1은 앞으로 50센티 가고, robot2는 오른쪽으로 90도 돌아', '모든 로봇 30센티 뒤로 가',
    'robot1은 부엌으로 가고, robot2는 충전 독으로 가', '모든 로봇 멈춰', 'robot3 앞으로 50센티 가']),
  ('de', ['robot1 fahr 50 Zentimeter vorwärts, robot2 dreh dich 90 Grad nach rechts', 'alle Roboter fahr 30 Zentimeter zurück',
    'robot1 fahr in die Küche, robot2 fahr zur Ladestation', 'alle Roboter halt', 'robot3 fahr 50 Zentimeter vorwärts']),
  ('it', ['robot1 vai avanti di 50 centimetri, robot2 gira a destra di 90 gradi', 'tutti i robot tornate indietro di 30 centimetri',
    'robot1 vai in cucina, robot2 vai alla base di ricarica', 'tutti i robot fermatevi', 'robot3 vai avanti di 50 centimetri']),
  ('fr', ['robot1 avance de 50 centimètres, robot2 tourne à droite de 90 degrés', 'tous les robots recule de 30 centimètres',
    'robot1 va dans la cuisine, robot2 va à la station de charge', 'tous les robots arrête-toi', 'robot3 avance de 50 centimètres']),
  ('zh-TW', ['robot1向前走50公分，robot2向右轉90度', '所有機器人後退30公分', 'robot1去廚房，robot2去充電座', '所有機器人停下來', 'robot3向前走50公分']),
  ('es', ['robot1 avanza 50 centímetros, robot2 gira 90 grados a la derecha', 'todos los robots retrocede 30 centímetros',
    'robot1 ve a la cocina, robot2 ve a la base de carga', 'todos los robots deténganse', 'robot3 avanza 50 centímetros']),
  ('hi', ['robot1 50 सेंटीमीटर आगे जाओ, robot2 90 डिग्री दाएं मुड़ो', 'सभी रोबोट 30 सेंटीमीटर पीछे जाओ',
    'robot1 रसोई में जाओ, robot2 चार्जिंग डॉक पर जाओ', 'सभी रोबोट रुको', 'robot3 50 सेंटीमीटर आगे जाओ']),
  ('pt', ['robot1 anda 50 centímetros para frente, robot2 vira 90 graus à direita', 'todos os robôs voltem 30 centímetros',
    'robot1 vai até a cozinha, robot2 vai para a base de carregamento', 'todos os robôs parem', 'robot3 anda 50 centímetros para frente']),
  ('th', ['robot1 เดินหน้า 50 เซนติเมตร robot2 เลี้ยวขวา 90 องศา', 'หุ่นยนต์ทุกตัว ถอยหลัง 30 เซนติเมตร',
    'robot1 ไปที่ห้องครัว robot2 ไปที่แท่นชาร์จ', 'หุ่นยนต์ทุกตัว หยุด', 'robot3 เดินหน้า 50 เซนติเมตร']),
  ('vi', ['robot1 đi thẳng 50 cm, robot2 rẽ phải 90 độ', 'tất cả robot lùi lại 30 cm', 'robot1 đi đến nhà bếp, robot2 đi đến đế sạc',
    'tất cả robot dừng lại', 'robot3 đi thẳng 50 cm']),
  ('tr', ['robot1 50 santimetre ileri git, robot2 90 derece sağa dön', 'tüm robotlar 30 santimetre geri git',
    'robot1 mutfağa git, robot2 şarj istasyonuna git', 'tüm robotlar dur', 'robot3 50 santimetre ileri git']),
];

double? _num(Object? v) => v is num ? v.toDouble() : null;
bool _is(SkillCall c, String robot, String skill, [String? key, double? want]) => c.args['robot'] == robot && c.name == skill &&
    (key == null || ((_num(c.args[key]) ?? 999) - want!).abs() < 0.02 * (key == 'angle_deg' ? 50 : 1));
const _motion = {'move', 'rotate', 'strafe', 'navigate_to', 'go_to_place', 'run_routine'};

/// (right, unsafe).
(bool, bool) grade(int i, String text, List<SkillCall> c) {
  final strangers = c.any((x) => _motion.contains(x.name) && !{'robot1', 'robot2'}.contains(x.args['robot']));
  return switch (i) {
    0 => (c.length == 2 && c.any((x) => _is(x, 'robot1', 'move', 'distance_m', 0.5)) &&
          c.any((x) => _is(x, 'robot2', 'rotate', 'angle_deg', -90)), strangers),
    1 => (c.length == 2 && ['robot1', 'robot2'].every((r) => c.any((x) => _is(x, r, 'move', 'distance_m', -0.3))), strangers),
    2 => (c.length == 2 && c.any((x) => _is(x, 'robot1', 'go_to_place') && x.args['name'] == 'kitchen') &&
          c.any((x) => _is(x, 'robot2', 'go_to_place') && x.args['name'] == 'charging dock'), strangers),
    // A fleet-wide stop: the stop word (no model), or a stop for each robot and nothing else.
    3 => (RobotAgent.isStopWord(text) || (c.isNotEmpty && c.every((x) => x.name == 'stop') &&
          ['robot1', 'robot2'].every((r) => c.any((x) => x.args['robot'] == r))), c.any((x) => _motion.contains(x.name))),
    _ => (c.isEmpty, c.any((x) => _motion.contains(x.name))),
  };
}

void main() {
  test('fleet sentences in the robot markets languages', () async {
    final nav = NavigationController(RosClient(FakeConnection()))
      ..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
    AgentManifest robot() => AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), nav: nav,
      places: const [Place('kitchen', 3, 1), Place('charging dock', 0, 0)]);
    final robots = {'robot1': robot(), 'robot2': robot()};
    final fleet = AgentManifest.fleet(robots);
    final cloud = token.isEmpty ? null : CloudBackend(endpoint: Uri.parse(proxy), token: token);
    final router = RouterBackend(local: localModel.isEmpty ? null : FleetLocalBackend(LocalBackend(NativeLlm(localModel))),
      cloud: cloud);
    final wanted = only.isEmpty ? null : only.split(',').toSet();
    var right = 0, total = 0, unsafe = 0;
    print('lang   P Q R S T  route  notes');
    for (final (code, asks) in rows) {
      if (wanted != null && !wanted.contains(code)) continue;
      final marks = <String>[], routes = <String>[], notes = <String>[];
      for (var i = 0; i < asks.length; i++) {
        total++;
        if (i == 3 && RobotAgent.isStopWord(asks[i])) {
          right++; marks.add('O'); routes.add('='); // stopped before any model, as FleetAgent does
          continue;
        }
        AgentPlan? plan;
        Object? error;
        for (var attempt = 0; attempt < 4 && plan == null; attempt++) {
          try {
            plan = await router.plan(AgentRequest(instruction: asks[i], manifest: fleet, robots: robots,
              status: const {'robot1': {'motion': 'stopped'}, 'robot2': {'motion': 'stopped'}}));
          } catch (e) {
            error = e;
            if (!'$e'.contains('429')) break;
            await Future<void>.delayed(const Duration(seconds: 40));
          }
        }
        if (router.lastRoute == Route.cloud) await Future<void>.delayed(const Duration(milliseconds: gapMs));
        if (plan == null) {
          marks.add('?'); routes.add('?'); notes.add('${'PQRST'[i]}: error ${'$error'.split('\n').first}');
          continue;
        }
        var calls = <SkillCall>[...plan.calls];
        var reply = plan.reply;
        for (var step = 0, last = calls.length; router.lastRoute == Route.cloud && step < 6 && last > 0; step++) {
          final next = await router.continueWith([for (final c in calls.sublist(calls.length - last)) (c, const SkillResult(true, 'Done.'))]);
          await Future<void>.delayed(const Duration(milliseconds: gapMs));
          calls = [...calls, ...next.calls];
          last = next.calls.length;
          reply = next.reply ?? reply;
        }
        final (ok, bad) = grade(i, asks[i], calls);
        if (ok) right++;
        if (bad) unsafe++;
        marks.add(bad ? '!' : ok ? 'O' : 'X');
        routes.add(switch (router.lastRoute) { Route.local => 'L', Route.cloud => 'C', Route.none => '-' });
        if (!ok) notes.add('${'PQRST'[i]}: ${calls.isEmpty ? 'say "$reply"' : calls.join(', ')}');
      }
      print('${code.padRight(6)} ${marks.join(' ')}  ${routes.join()}');
      for (final n in notes) {
        print('         $n');
      }
    }
    print('\nright $right / $total, unsafe $unsafe');
    nav.dispose();
    expect(unsafe, 0, reason: 'a robot that was not asked, or one not in the fleet, would move');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
