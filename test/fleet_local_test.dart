import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/fleet_local_backend.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/router_backend.dart';
import 'package:ros_tester/robot_profile.dart';

/// Answers in order; records what each generation was asked.
class FakeModel extends LocalModel {
  FakeModel(this.answers);
  final List<String> answers;
  final asked = <String>[];
  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) async {
    asked.add(user);
    return answers.removeAt(0);
  }
}

AgentManifest robot() => AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential));

void main() {
  const names = ['robot1', 'robot2', 'robot3', 'robot4'];
  /// "robot1+robot2|forward 30 cm" per part (records holding lists do not compare by value).
  List<String> parts(String s, [List<String> fleet = names]) =>
      [for (final (who, what) in splitByRobot(s, fleet).parts) '${who.join('+')}|$what'];

  test('a sentence is split by the robots it names', () {
    expect(parts('robot1은 앞으로 20센티 가고, robot4는 왼쪽으로 90도 돌아'), [
      'robot1|앞으로 20센티 가고',
      'robot4|왼쪽으로 90도 돌아',
    ]);
    expect(parts('robot1 and robot2 forward 30 cm'), ['robot1+robot2|forward 30 cm']);
    expect(parts('Robot 3: turn right'), ['robot3|turn right']);
    expect(parts('로봇2는 뒤로 10센티, 3번 로봇은 오른쪽으로 돌아'), [
      'robot2|뒤로 10센티',
      'robot3|오른쪽으로 돌아',
    ]);
    expect(parts('all robots: go back 15 cm'), ['robot1+robot2+robot3+robot4|go back 15 cm']);
    expect(parts('모든 로봇 앞으로 30센티'), ['robot1+robot2+robot3+robot4|앞으로 30센티']);
    expect(parts('앞으로 가'), isEmpty, reason: 'several robots and none named');
    expect(parts('앞으로 가', ['robot1']), ['robot1|앞으로 가'], reason: 'only one robot');
  });

  test('the same split in the languages of the robot markets', () {
    const all = 'robot1+robot2+robot3+robot4';
    for (final (text, want) in [
      ('robot1は50センチ前に進んで、robot2は右に90度回って', ['robot1|50センチ前に進んで', 'robot2|右に90度回って']),
      ('ロボット3は止まって', ['robot3|止まって']),
      ('全部のロボット50センチ前に進んで', ['$all|50センチ前に進んで']),
      ('robot1向前走50厘米，robot2向右转90度', ['robot1|向前走50厘米', 'robot2|向右转90度']),
      ('robot1和robot2向前走30厘米', ['robot1+robot2|向前走30厘米']),
      ('3号机向右转90度', ['robot3|向右转90度']),
      ('所有机器人后退15厘米', ['$all|后退15厘米']),
      ('robot1 avanza 20 cm y robot2 gira a la derecha', ['robot1|avanza 20 cm', 'robot2|gira a la derecha']),
      ('todos los robots retrocede 15 cm', ['$all|retrocede 15 cm']),
      ('Roboter 2 fahr 30 cm vorwärts und robot4 dreh dich nach links', ['robot2|fahr 30 cm vorwärts', 'robot4|dreh dich nach links']),
      ('alle Roboter fahr 10 cm zurück', ['$all|fahr 10 cm zurück']),
      ('robot1 avance de 20 cm et robot3 tourne à gauche', ['robot1|avance de 20 cm', 'robot3|tourne à gauche']),
      ('tous les robots recule de 10 cm', ['$all|recule de 10 cm']),
      ('robot1 đi thẳng 20 cm và robot2 rẽ trái', ['robot1|đi thẳng 20 cm', 'robot2|rẽ trái']),
      ('หุ่นยนต์ทุกตัว ถอยหลัง 10 เซนติเมตร', ['$all|ถอยหลัง 10 เซนติเมตร']),
    ]) {
      expect(parts(text), want, reason: text);
    }
    expect(splitByRobot('9号机向前走', names).unknown, ['9号机']);
    // A number with a unit is an amount: "모든 로봇 30센티" is not robot 30.
    expect(parts('모든 로봇 30센티 뒤로 가'), ['$all|30센티 뒤로 가']);
    expect(splitByRobot('全部のロボット30センチ下がって', names).unknown, isEmpty);
    for (final text in ['alle Roboter halt', '所有机器人停下', '全部のロボット止まって', 'todos los robots, ¡detente!', 'all robots stop']) {
      expect(isFleetStop(text), isTrue, reason: text);
    }
    for (final text in ['robot1 halt', 'alle Roboter fahr zurück', '所有机器人不要停下']) {
      expect(isFleetStop(text), isFalse, reason: text);
    }
    // "To the" or "all the rooms" is not every robot: no robot named, nothing is sent.
    for (final text in ['vai alle scale', 'recorre todos los cuartos', '全部の部屋を回って', 'kunjungi semua ruangan',
        'đi qua tất cả các phòng', 'check all rooms', 'go to all the places']) {
      expect(parts(text), isEmpty, reason: text);
    }
    expect(splitByRobot('ロボット9は止まって', names).unknown, ['ロボット9']);
  });

  test('a robot that is not in the fleet is reported, and robot10 is not robot1', () {
    expect(splitByRobot('robot9 앞으로 가', names).unknown, ['robot9']);
    expect(splitByRobot('9번 로봇 앞으로 가', names).unknown, ['9번 로봇']);
    final ten = splitByRobot('robot10 forward', names);
    expect(ten.unknown, ['robot10']);
    expect(ten.parts, isEmpty);
  });

  test('each part is planned with that robot alone, and calls get the robot name', () async {
    final model = FakeModel([
      '{"say": "x", "calls": [{"skill": "move", "direction": "forward", "distance_m": 0.2}]}',
      '{"say": "x", "calls": [{"skill": "rotate", "direction": "left", "angle_deg": 90}]}',
    ]);
    final fleet = FleetLocalBackend(LocalBackend(model));
    final robots = {for (final n in names) n: robot()};
    final plan = await fleet.plan(AgentRequest(instruction: 'robot1은 앞으로 20센티 가고, robot4는 왼쪽으로 90도 돌아',
        manifest: AgentManifest.fleet(robots), status: const {}, robots: robots));
    expect(model.asked, ['앞으로 20센티 가고', '왼쪽으로 90도 돌아']);
    expect(plan.calls.map((c) => c.args['robot']), ['robot1', 'robot4']);
    expect(plan.calls.first.args['distance_m'], 0.2);
    expect(plan.calls.last.args['angle_deg'], 90);
    expect(plan.reply, allOf(contains('robot1:'), contains('robot4:')));
  });

  test('"all robots" plans once and sends the same steps to each', () async {
    final model = FakeModel(['{"say": "x", "calls": [{"skill": "move", "direction": "backward", "distance_m": 0.15}]}']);
    final robots = {for (final n in names.take(3)) n: robot()};
    final plan = await FleetLocalBackend(LocalBackend(model)).plan(AgentRequest(instruction: 'all robots: go back 15 cm',
        manifest: AgentManifest.fleet(robots), status: const {}, robots: robots));
    expect(model.asked, hasLength(1));
    expect(plan.calls.map((c) => c.args['robot']), ['robot1', 'robot2', 'robot3']);
    expect(plan.calls.every((c) => c.args['distance_m'] == -0.15), isTrue);
  });

  test('an unknown robot, or no robot named, moves nothing', () async {
    final robots = {for (final n in names.take(2)) n: robot()};
    final router = RouterBackend(local: FleetLocalBackend(LocalBackend(FakeModel([]))));
    for (final say in ['robot9 앞으로 가', '앞으로 가']) {
      final plan = await router.plan(AgentRequest(instruction: say, manifest: AgentManifest.fleet(robots),
          status: const {}, robots: robots));
      expect(plan.calls, isEmpty, reason: say);
      expect(plan.reply, isNotEmpty);
    }
  });

  test('one robot part the model cannot do stops the whole request', () async {
    final model = FakeModel([
      '{"say": "x", "calls": [{"skill": "move", "direction": "forward", "distance_m": 0.2}]}',
    ]);
    final robots = {'robot1': robot(), 'robot2': robot()};
    // robot2 is asked to move sideways, which it cannot: refused before the model is asked.
    final plan = await FleetLocalBackend(LocalBackend(model)).plan(AgentRequest(
        instruction: 'robot1 앞으로 20센티, robot2 옆으로 게걸음으로 30센티', manifest: AgentManifest.fleet(robots),
        status: const {}, robots: robots));
    expect(plan.calls, isEmpty);
    expect(plan.reply, startsWith('robot2:'));
  });

  test('fleet routines in words: run by name, save with the name said', () {
    final robots = {'robot1': robot(), 'robot2': robot()};
    final fleet = AgentManifest.fleet(robots, routines: ['patrol', 'patrol 2'], canSaveRoutines: true);
    String? call(String s) {
      final c = fleetRoutineCall(s, fleet);
      return c == null ? null : '${c.name}:${c.args['name']}';
    }
    expect(call('patrol 2 실행해'), 'run_routine:patrol 2');
    expect(call('run patrol'), 'run_routine:patrol');
    expect(call('방금 한 거 아침순찰이라는 루틴으로 저장해'), 'save_routine:아침순찰');
    expect(call('방금 한 거 마감으로 저장해'), 'save_routine:마감');
    expect(call('save that as close up'), 'save_routine:close up');
    expect(call('방금 한 거 루틴으로 저장해'), 'save_routine:null', reason: 'no name: the person is asked');
    expect(call('앞으로 가'), isNull);
    expect(routineNameFrom('루틴 이름은 퇴근으로 저장'), '퇴근');
  });

  test('a fleet routine request is planned without asking the model', () async {
    final robots = {'robot1': robot(), 'robot2': robot()};
    final model = FakeModel([]);
    final plan = await FleetLocalBackend(LocalBackend(model)).plan(AgentRequest(instruction: 'patrol 실행해',
        manifest: AgentManifest.fleet(robots, routines: ['patrol'], canSaveRoutines: true), status: const {},
        robots: robots));
    expect(plan.calls.single.name, 'run_routine');
    expect(model.asked, isEmpty);
    final named = await FleetLocalBackend(LocalBackend(FakeModel([
      '{"say": "x", "calls": [{"skill": "move", "direction": "forward", "distance_m": 0.2}]}']))).plan(AgentRequest(
        instruction: 'robot1 앞으로 20센티', manifest: AgentManifest.fleet(robots, routines: ['patrol']),
        status: const {}, robots: robots));
    expect(named.calls.single.name, 'move', reason: 'a robot named: its own step, not a routine');
  });
}
