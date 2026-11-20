import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/instruction_language.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/route_policy.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_profile.dart';

class RecordingModel extends LocalModel {
  int calls = 0;
  @override
  Future<String> generate({required String system, required String user, required String grammar, int maxTokens = 160}) async {
    calls++;
    // A deliberately unsafe interpretation for a conditional request: the guard must never ask it.
    return '{"calls":[{"skill":"move","direction":"forward","distance_m":0.5}]}';
  }
}
class RecordingCloud extends AgentBackend {
  int calls = 0;
  @override
  String get name => 'cloud';
  @override
  Future<AgentPlan> plan(AgentRequest request) async { calls++; return const AgentPlan(reply: 'Online interpretation.'); }
}
AgentManifest robot({bool remember = false}) => AgentManifest.build(
  profile: RobotProfile.defaults(DriveType.differential), canRemember: remember);
AgentRequest request(String text, [AgentManifest? m]) => AgentRequest(instruction: text, manifest: m ?? robot(), status: const {});

// Independent compatibility fixtures from the previously measured 12-language local-model survey.
// These assert routing eligibility, not accuracy of a model's generated movement plan.
const direct = [
  ('Korean', ['앞으로 50센티 가', '오른쪽으로 90도 돌아', '30센티 뒤로 가고 왼쪽으로 돌아']),
  ('English', ['go forward 50 cm', 'turn right 90 degrees', 'go back 30 cm and turn left']),
  ('Japanese', ['50センチ前に進んで', '右に90度回って', '30センチ下がって左に曲がって']),
  ('Chinese', ['向前走50厘米', '向右转90度', '后退30厘米然后左转']),
  ('Spanish', ['avanza 50 centímetros', 'gira 90 grados a la derecha', 'retrocede 30 cm y gira a la izquierda']),
  ('German', ['fahr 50 Zentimeter vorwärts', 'dreh dich 90 Grad nach rechts', 'fahr 30 cm zurück und dreh nach links']),
  ('French', ['avance de 50 centimètres', 'tourne à droite de 90 degrés', 'recule de 30 cm et tourne à gauche']),
  ('Vietnamese', ['đi thẳng 50 cm', 'rẽ phải 90 độ', 'lùi lại 30 cm rồi rẽ trái']),
  ('Thai', ['เดินหน้า 50 เซนติเมตร', 'เลี้ยวขวา 90 องศา', 'ถอยหลัง 30 เซนติเมตรแล้วเลี้ยวซ้าย']),
  ('Arabic', ['تقدم 50 سنتيمتر', 'استدر يمينا 90 درجة', 'ارجع 30 سنتيمتر ثم استدر يسارا']),
  ('Indonesian', ['maju 50 sentimeter', 'belok kanan 90 derajat', 'mundur 30 cm lalu belok kiri']),
  ('Russian', ['проедь вперёд 50 сантиметров', 'повернись направо на 90 градусов', 'отъедь назад на 30 см и повернись налево']),
];
const online = [
  '人が見えるまで50センチ前に進んで', 'カメラで前を見て', '私の名前を覚えて',
  '向前走50厘米直到看到人', '用摄像头看看前面', '记住我的名字', '不要向前走50厘米',
  'avanza 50 centímetros hasta que veas una persona', 'mira delante con la cámara', 'no avances 50 cm',
  'fahr 50 Zentimeter vorwärts bis du jemanden siehst', 'schau durch die Kamera',
  'avance de 50 centimètres jusqu’à voir une personne', 'regarde avec la caméra',
  'đi thẳng 50 cm đến khi nhìn thấy người', 'nhớ tên tôi',
  'เดินหน้า 50 เซนติเมตรจนกว่าจะเห็นคน', 'ดูผ่านกล้อง',
  'تقدم 50 سنتيمتر حتى ترى شخصا', 'لا تتحرك',
  'maju 50 sentimeter sampai melihat orang', 'ingat nama saya',
  'проедь вперёд 50 сантиметров пока не увидишь человека', 'посмотри через камеру',
  'move forward 50 cm 如果门开了', 'turn left si ves una persona', '前진 말고 기다려',
  'όταν ανοίξει η πόρτα προχώρα', 'दरवाजा खुलने पर आगे बढ़ो', 'hazlo',
];

void main() {
  for (final (language, examples) in direct) {
    test('$language measured direct syntax remains eligible for the on-device planner', () {
      for (final text in examples) {
        expect(RoutePolicy.decide(text, robot()).handler, Handler.local, reason: text);
      }
    });
  }
  test('three steps joined by a comma and a word stay on the phone (robot-market language survey)', () {
    for (final text in ['1メートル前に進んで、左に90度回って、それから50センチ下がって', '向前走1米，左转90度，然后后退50厘米',
        'avanza 1 metro, gira 90 grados a la izquierda y luego retrocede 50 centímetros',
        'fahr 1 Meter vorwärts, dreh dich 90 Grad nach links und fahr dann 50 Zentimeter zurück',
        'đi thẳng 1 mét, rẽ trái 90 độ, rồi lùi lại 50 cm', 'เดินหน้า 1 เมตร เลี้ยวซ้าย 90 องศา แล้วถอยหลัง 50 เซนติเมตร']) {
      expect(RoutePolicy.decide(text, robot()).handler, Handler.local, reason: text);
    }
    // Still online: a negation, a condition, a question.
    for (final text in ['不要往前走，只向右转45度', 'si la batterie est sous 20 %, va à la station de charge', 'wie viel Akku ist noch übrig?']) {
      expect(RoutePolicy.decide(text, robot()).handler, Handler.cloud, reason: text);
    }
    expect(InstructionLanguagePolicy.unavailable('si la batterie est sous 20 %, va à la cuisine', robot()), startsWith('Cette instruction'));
  });
  test('direct motion in the measured languages is read by its grammar, the same every time', () {
    String read(String text) => '${InstructionLanguagePolicy.directCalls(text, robot())}';
    for (final (language, examples) in direct) {
      if (language == 'Korean' || language == 'English') continue; // the model and its tests cover these
      expect(read(examples[0]), '[move(distance_m: 0.5)]', reason: examples[0]);
      expect(read(examples[1]), '[rotate(angle_deg: -90.0)]', reason: examples[1]);
      expect(read(examples[2]), '[move(distance_m: -0.3), rotate(angle_deg: 90.0)]', reason: examples[2]);
    }
    expect(read('1メートル前に進んで、左に90度回って、それから50センチ下がって'),
        '[move(distance_m: 1.0), rotate(angle_deg: 90.0), move(distance_m: -0.5)]');
    expect(read('rẽ phải 90 độ'), '[rotate(angle_deg: -90.0)]');
    // Not a direct sentence: left to the model or the online assistant.
    for (final text in ['不要往前走，只向右转45度', 'avanza 50 cm hasta la puerta', 'go forward 50 cm', '앞으로 50센티 가']) {
      expect(InstructionLanguagePolicy.directCalls(text, robot()), isNull, reason: text);
    }
  });
  test('unrecognized conditions, negations, camera and memory requests go straight to the online planner', () async {
    for (final text in online) {
      final model = RecordingModel(), cloud = RecordingCloud(); var uses = 0;
      final router = RouterBackend(local: LocalBackend(model), cloud: cloud, onCloudUse: () => uses++);
      final plan = await router.plan(request(text));
      expect((model.calls, cloud.calls, uses), (0, 1, 1), reason: text);
      expect(plan.calls, isEmpty);
    }
  });
  test('missing online access or quota never executes a guessed local plan', () async {
    for (final text in online) {
      for (final withCloud in [false, true]) {
        final model = RecordingModel(), cloud = RecordingCloud(); var uses = 0;
        final router = RouterBackend(local: LocalBackend(model), cloud: withCloud ? cloud : null,
          cloudAllowed: () => false, onCloudUse: () => uses++);
        final plan = await router.plan(request(text));
        expect(plan.calls, isEmpty, reason: text);
        expect(plan.reply, isNotEmpty, reason: text);
        expect((model.calls, cloud.calls, uses), (0, 0, 0), reason: text);
      }
    }
  });
  test('a directly used local backend also hands off unsupported structure before generation', () async {
    final model = RecordingModel();
    final plan = await LocalBackend(model).plan(request('向前走50厘米直到看到人'));
    expect(plan.handoff, isTrue); expect(plan.calls, isEmpty); expect(model.calls, 0);
    expect(plan.reply, contains('没有执行'));
  });
  test('foreign names do not turn an English command into a foreign-language request', () {
    final m = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential),
      places: const [Place('東京', 1, 2), Place('Si', 2, 3), Place('José', 3, 4)]);
    for (final name in ['東京', 'Si', 'José']) {
      expect(RoutePolicy.decide('go to $name', m).handler, Handler.local);
    }
    final fleet = AgentManifest.fleet({'ロボ1': robot(), 'robot2': robot()});
    expect(RoutePolicy.decide('ロボ1 go forward 20 cm, robot2 turn left', fleet).handler, Handler.local);
    expect(RoutePolicy.decide('go to 東京 如果门开了', m).handler, Handler.cloud);
  });
  test('an arbitrary quoted condition is not masked like a saved name', () {
    expect(RoutePolicy.decide('move forward "如果门开了"', robot()).handler, Handler.cloud);
    expect(RoutePolicy.decide('向前走50厘米然后左转然后左转然后左转然后左转', robot()).handler, Handler.cloud);
  });
  test('explicit English memory instructions retain foreign text as data without a model', () async {
    final model = RecordingModel(), cloud = RecordingCloud();
    final router = RouterBackend(local: LocalBackend(model), cloud: cloud);
    final plan = await router.plan(request('your name is さくら', robot(remember: true)));
    expect(plan.calls.single.name, 'update_profile');
    expect(plan.calls.single.args['value'], 'さくら');
    expect((model.calls, cloud.calls), (0, 0));
    final note = await router.plan(request('remember that 如果门开了 is a sign on the wall', robot(remember: true)));
    expect(note.calls.single.name, 'remember'); expect((model.calls, cloud.calls), (0, 0));
  });
  test('stop recognition requires an entire affirmative stop, not a condition or negation', () {
    for (final text in ['止まって！', '停止', '停下', 'detente', 'párate', 'arrête-toi', 'stopp', 'dừng lại',
      'หยุด', 'توقف', 'berhenti', 'остановись', 'pare', 'रुक जाओ',
      // Measured gaps in the robot-market language survey (tool/live_language_matrix_test.dart).
      '¡detente!', '停下來！', 'fermati!', 'dur!', 'durun', 'रुकें', 'para!', 'deténganse', 'fermatevi', 'parem', 'arrêtez-vous', 'haltet an', 'остановитесь']) {
      expect(RobotAgent.isStopWord(text), isTrue, reason: text);
    }
    for (final text in ['no pares', '不要停止', '停止しないで', 'не останавливайся', 'لا تتوقف', 'arrête si tu vois quelqu’un',
      'stop when the door opens', 'a place named stop', 'robot1 stop', 'non fermarti', 'durma', '不要停下來']) {
      expect(RobotAgent.isStopWord(text), isFalse, reason: text);
    }
  });
}
