// ignore_for_file: avoid_print
// How well the on-device model understands commands in other languages. Prints a table; does not fail
// on wrong answers (it is a survey), only on errors.
//   MOBILE_ROS_LLM_MODEL=<gguf> flutter test tool/live_local_languages_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/llm.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/robot_profile.dart';

/// (language, "go forward 50 cm", "turn right 90 degrees", "go back 30 cm and turn left")
const commands = [
  ('Korean', '앞으로 50센티 가', '오른쪽으로 90도 돌아', '30센티 뒤로 가고 왼쪽으로 돌아'),
  ('English', 'go forward 50 cm', 'turn right 90 degrees', 'go back 30 cm and turn left'),
  ('Japanese', '50センチ前に進んで', '右に90度回って', '30センチ下がって左に曲がって'),
  ('Chinese', '向前走50厘米', '向右转90度', '后退30厘米然后左转'),
  ('Spanish', 'avanza 50 centímetros', 'gira 90 grados a la derecha', 'retrocede 30 cm y gira a la izquierda'),
  ('German', 'fahr 50 Zentimeter vorwärts', 'dreh dich 90 Grad nach rechts', 'fahr 30 cm zurück und dreh nach links'),
  ('French', 'avance de 50 centimètres', 'tourne à droite de 90 degrés', 'recule de 30 cm et tourne à gauche'),
  ('Vietnamese', 'đi thẳng 50 cm', 'rẽ phải 90 độ', 'lùi lại 30 cm rồi rẽ trái'),
  ('Thai', 'เดินหน้า 50 เซนติเมตร', 'เลี้ยวขวา 90 องศา', 'ถอยหลัง 30 เซนติเมตรแล้วเลี้ยวซ้าย'),
  ('Arabic', 'تقدم 50 سنتيمتر', 'استدر يمينا 90 درجة', 'ارجع 30 سنتيمتر ثم استدر يسارا'),
  ('Indonesian', 'maju 50 sentimeter', 'belok kanan 90 derajat', 'mundur 30 cm lalu belok kiri'),
  ('Russian', 'проедь вперёд 50 сантиметров', 'повернись направо на 90 градусов', 'отъедь назад на 30 см и повернись налево'),
];

void main() {
  test('commands in many languages', () async {
    final llm = NativeLlm((await LocalModelFile.path())!);
    addTearDown(llm.dispose);
    final backend = LocalBackend(llm);
    final manifest = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential));
    Future<String> ask(String text) async {
      final plan = await backend.plan(AgentRequest(instruction: text, manifest: manifest, status: const {}));
      return plan.handoff ? 'handoff' : plan.calls.map((c) => '$c').join(', ');
    }
    bool near(Object? v, double want) => v is num && (v - want).abs() < 0.011;
    var right = 0, total = 0;
    for (final (lang, forward, turnRight, combo) in commands) {
      final a = await ask(forward), b = await ask(turnRight), c = await ask(combo);
      final okA = a == 'move(distance_m: 0.5)';
      final okB = b == 'rotate(angle_deg: -90)';
      final okC = c.startsWith('move(distance_m: -0.3)') && c.contains('rotate(angle_deg: 90');
      right += [okA, okB, okC].where((x) => x).length;
      total += 3;
      print('${lang.padRight(11)} ${okA ? 'O' : 'X'} ${okB ? 'O' : 'X'} ${okC ? 'O' : 'X'}   '
          '${okA ? '' : '[$a] '}${okB ? '' : '[$b] '}${okC ? '' : '[$c]'}');
      expect(near(0.5, 0.5), isTrue);
    }
    print('total $right / $total');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
