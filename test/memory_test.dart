import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/route_policy.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/voice.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_profile.dart';

/// Keeps scopes in a map, and counts writes.
class MapStore implements MemoryStore {
  final data = <String, List<MemoryItem>>{};
  int writes = 0;
  @override
  Future<List<MemoryItem>> read(String scope) async => [...?data[scope]];
  @override
  Future<void> write(String scope, List<MemoryItem> items) async { writes++; data[scope] = [...items]; }
  @override
  Future<void> delete(String scope) async => data.remove(scope);
}

AgentManifest robot({bool camera = false}) => AgentManifest.build(
    profile: RobotProfile.defaults(DriveType.differential, cameraTopic: camera ? '/camera/image_raw/compressed' : ''),
    canRemember: true);

void main() {
  test('keyed facts replace each other; notes add up; a reload reads the same; the stored form is compact', () async {
    final store = MapStore();
    final m = Memory('robot:x', store: store);
    await m.setProfile('name', '순돌이');
    await m.setProfile('name', '  Sunny ');
    await m.add('note', '2층 계단 근처는 가지 마');
    await m.add('note', '2층 계단 근처는 가지 마'); // the same again: refreshed, not doubled
    await m.add('note', 'the door sticks');
    expect(m.profile('name'), 'Sunny');
    expect(m.ofKind('note').map((i) => i.text), ['2층 계단 근처는 가지 마', 'the door sticks']);
    final again = Memory('robot:x', store: store);
    await again.load();
    expect(again.profile('name'), 'Sunny');
    expect(again.ofKind('note'), hasLength(2));
    await again.setProfile('name', '');
    expect(again.profile('name'), isNull, reason: 'empty removes');
    expect(store.data['robot:x']!.first.toJson().keys, isNot(contains('src')), reason: 'defaults are not written');
  });

  test('over the limit, the least used and oldest unpinned records go; pinned ones stay', () async {
    var now = DateTime(2026, 1, 1);
    final m = Memory('robot:y', store: MapStore(), maxItems: 3, clock: () => now = now.add(const Duration(minutes: 1)));
    await m.add('note', 'keep me', pinned: true);
    final used = await m.add('note', 'used often');
    await m.add('note', 'old');
    await m.touch([used!]);
    await m.add('note', 'new');
    expect(m.items.map((i) => i.text), ['keep me', 'used often', 'new']);
  });

  test('the notes given to the assistant are the relevant ones, within the budget', () async {
    final m = Memory('robot:z', store: MapStore());
    await m.add('note', 'the kitchen floor is slippery');
    await m.add('note', 'charge before 6 pm');
    await m.add('note', 'x' * 250);
    final picked = m.relevant('go to the kitchen', budget: 60);
    expect(picked.first.text, 'the kitchen floor is slippery');
    expect(picked.fold<int>(0, (n, i) => n + i.text.length), lessThanOrEqualTo(60));
  });

  test('the persona reads the robot and the person, and is told to the assistant', () async {
    SharedPreferences.setMockInitialValues({});
    final mem = Memory('robot:p', store: MapStore()), person = Memory('user', store: MapStore());
    await mem.setProfile(RobotPersona.nameKey, '순돌이');
    await mem.setProfile(RobotPersona.roleKey, '창고 야간 순찰');
    await person.setProfile(RobotPersona.callPersonKey, '민수');
    await mem.add('note', '2층 계단 근처는 가지 마', pinned: true);
    final p = RobotPersona.from(mem, person);
    final m = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), persona: p, canRemember: true);
    expect(m.describe(), allOf(contains('"순돌이"'), contains('창고 야간 순찰'), contains('"민수"'), contains('계단')));
    expect(m.skill('update_profile')!.param('field')!.values, containsAll(['robot_name', 'call_person']));
    expect(AgentManifest.fleet({'robot1': m, 'robot2': robot()}).fleetAliases, {'순돌이': 'robot1'});
  });

  test('what to remember is found by its words, not by the model', () {
    final m = robot();
    String? call(String s) {
      final c = memoryCall(s, m);
      return c == null ? null : '${c.name} ${c.args.values.join('=')}';
    }
    expect(call('앞으로 나를 민수라고 불러'), 'update_profile call_person=민수');
    expect(call('call me Minsu'), 'update_profile call_person=Minsu');
    expect(call('네 이름은 순돌이야'), 'update_profile robot_name=순돌이');
    expect(call('your name is Sunny'), 'update_profile robot_name=Sunny');
    expect(call('너는 창고 순찰 담당이야'), 'update_profile robot_role=창고 순찰');
    expect(call('2층 계단 근처는 가지 마, 기억해'), 'remember 2층 계단 근처는 가지 마');
    expect(call('remember that the door sticks'), 'remember the door sticks');
    expect(call('앞으로 50센티 가'), isNull);
    expect(call('부엌으로 가'), isNull);
    // Other robot-market languages: the same three things, offline, kept word for word.
    for (final (text, want) in [
      ('これからは私をAlexと呼んで', 'update_profile call_person=Alex'),
      ('以后叫我Alex', 'update_profile call_person=Alex'), ('以後叫我小明吧', 'update_profile call_person=小明'),
      ('a partir de ahora llámame Alex', 'update_profile call_person=Alex'),
      ('nenn mich ab jetzt Alex', 'update_profile call_person=Alex'),
      ('à partir de maintenant, appelle-moi Alex', 'update_profile call_person=Alex'),
      ("d'ora in poi chiamami Alex", 'update_profile call_person=Alex'),
      ('a partir de agora me chama de Alex', 'update_profile call_person=Alex'),
      ('từ giờ hãy gọi tôi là Alex', 'update_profile call_person=Alex'), ('ต่อจากนี้เรียกฉันว่า Alex', 'update_profile call_person=Alex'),
      ('君の名前はポチだよ', 'update_profile robot_name=ポチ'), ('你的名字是小白', 'update_profile robot_name=小白'),
      ('tu nombre es Rayo', 'update_profile robot_name=Rayo'), ('dein Name ist Blitz', 'update_profile robot_name=Blitz'),
      ('覚えておいて：2階の階段には近づかない', 'remember 2階の階段には近づかない'),
      ('记住：厨房的门很重', 'remember 厨房的门很重'),
      ('recuerda que la puerta de la cocina se atasca', 'remember la puerta de la cocina se atasca'),
      ('merk dir, dass die Tür klemmt', 'remember die Tür klemmt'),
      ('souviens-toi que la porte coince', 'remember la porte coince'),
      ('ricorda che la porta è pesante', 'remember la porta è pesante'),
      ('lembre-se de que a porta emperra', 'remember a porta emperra'),
    ]) {
      expect(call(text), want, reason: text);
    }
    // Asking, and sentences that only look alike, write nothing.
    for (final text in ['君の名前は何？', '你叫什么名字？', '你的名字是什么', '¿cómo te llamas?', 'wie heißt du?',
        'comment tu t’appelles ?', 'come ti chiami?', 'qual é o seu nome?', '他叫我过去', '向前走50厘米', 'avanza 50 cm']) {
      expect(call(text), isNull, reason: text);
    }
    expect(memoryCall('네 이름은 순돌이야', AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential))),
        isNull, reason: 'no memory on this robot');
  });

  test('on the phone: direct commands; online: seeing, judging, searching, talking, long requests', () {
    String where(String s, {bool camera = true}) => RoutePolicy.decide(s, robot(camera: camera)).handler.name;
    for (final s in ['앞으로 50센티 가', '왼쪽으로 90도 돌고 1미터 가', '부엌으로 가', 'patrol 실행해', '멈춰',
        '배터리 얼마나 남았어?', '지금 어디야?', 'go back half a meter']) {
      expect(where(s), 'local', reason: s);
    }
    for (final s in ['앞에 뭐가 보여?', '카메라로 봐줘', '사람이 보이면 멈춰', '벽에 닿을 때까지 가', '빨간 공 찾아',
        '나 따라와', '안녕 순돌아', '왜 멈췄어?', 'if the door is open go in',
        '앞으로 가고, 돌고, 다시 가고, 멈추고, 뒤로 가']) {
      expect(where(s), 'cloud', reason: s);
    }
    expect(where('앞에 뭐가 보여?', camera: false), isNot('cloud: needs the camera'));
  });

  test('the on-device reply uses the right Korean particle for the name', () {
    String reply(String field, String value) => planSentence([SkillCall('update_profile', {'field': field, 'value': value})], ReplyLanguage.ko);
    expect(reply('call_person', '민수'), '앞으로 민수라고 부를게요.');
    expect(reply('call_person', '민준'), '앞으로 민준이라고 부를게요.');
    expect(reply('robot_name', '순돌이'), '좋아요, 제 이름은 이제 순돌이예요.');
    expect(reply('robot_name', '별'), '좋아요, 제 이름은 이제 별이에요.');
  });

  test('what was asked and how it went is kept, and given to the online assistant only', () async {
    final mem = Memory('robot:e', store: MapStore()), person = Memory('user-e', store: MapStore());
    await mem.setProfile(RobotPersona.nameKey, '순돌이');
    await RobotAgent.rememberRun(mem, const AgentRun(instruction: '앞으로 20센티 가',
        results: [SkillResult(true, 'Moved 0.19 m forward.')]));
    await RobotAgent.rememberRun(mem, const AgentRun(instruction: '입구로 가', error: 'Nav2 aborted the goal'));
    await RobotAgent.rememberRun(mem, const AgentRun(instruction: '멈춰', results: [SkillResult(true, 'Stopped.')]));
    await RobotAgent.rememberRun(mem, const AgentRun(instruction: '네 이름은 순돌이야',
        results: [SkillResult(true, 'Saved: robot name is "순돌이".')]));
    final episodes = mem.ofKind('episode').map((e) => e.text).toList();
    expect(episodes, hasLength(2), reason: 'stops and remembering are not events');
    expect(episodes.first, matches(RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d "앞으로 20센티 가" -> Moved 0\.19 m forward\.$')));
    expect(episodes.last, contains('Not done: Nav2 aborted the goal'));

    final p = RobotPersona.from(mem, person);
    final m = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), persona: p, canRemember: true);
    expect(m.describe(), allOf(contains('What happened lately'), contains('입구로 가')));
    expect(m.describe(brief: true), allOf(contains('순돌이'), isNot(contains('What happened lately'))),
        reason: 'the on-device model gets the same text every time');
  });

  test('asking is not telling, and a polite command asked as a question is still a command', () {
    final m = robot();
    for (final s in ['네 이름은 뭐야?', '네 이름은 뭐니', '나를 뭐라고 불러?', '너는 뭐 담당이야?']) {
      expect(memoryCall(s, m), isNull, reason: s);
    }
    expect(memoryCall('네 이름은 순돌이야', m)?.args['value'], '순돌이');
    String where(String s) => RoutePolicy.decide(s, robot()).handler.name;
    for (final s in ['앞으로 가 줄래?', '부엌으로 갈 수 있어?', '오른쪽으로 90도 돌아 줄래?', 'can you turn left?',
        '1미터 앞으로 가면 돼']) {
      expect(where(s), 'local', reason: s);
    }
    for (final s in ['왜 멈췄어?', '안녕', '벽이 보이면 멈춰']) {
      expect(where(s), 'cloud', reason: s);
    }
  });
}
