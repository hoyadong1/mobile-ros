import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/local/local_backend.dart';
import 'package:ros_tester/agent/manifest.dart';
import 'package:ros_tester/agent/robot_tools.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/voice.dart';
import 'package:ros_tester/controllers/drive_controller.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/places.dart';
import 'package:ros_tester/robot_capabilities.dart';
import 'package:ros_tester/robot_log.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/ros_client.dart';

import 'support/fake_ros_connection.dart';

/// A robot that answers each subscription with the messages it has for that topic.
class TopicRobot extends FakeConnection {
  final topics = <String, List<Map<String, dynamic>>>{};

  @override
  void send(Map<String, dynamic> message) {
    super.send(message);
    if (message['op'] != 'subscribe') return;
    final topic = message['topic'] as String;
    final msgs = topics[topic];
    if (msgs == null) return;
    scheduleMicrotask(() {
      for (final m in msgs) {
        if (!events.isClosed) events.add({'op': 'publish', 'topic': topic, 'msg': m});
      }
    });
  }
}

Map<String, dynamic> _tf(String parent, String child, double x, double y, [double yaw = 0]) => {
  'header': {'frame_id': parent}, 'child_frame_id': child, 'transform': {
    'translation': {'x': x, 'y': y, 'z': 0.0}, 'rotation': quaternionFromYaw(yaw)}};

// A 4 m x 3 m L-shaped room (0.05 m cells): only one spot fits a scan.
const _w = 80, _h = 60, _res = 0.05;
final _cells = [
  for (var r = 0; r < _h; r++)
    for (var c = 0; c < _w; c++)
      r == 0 || c == 0 || r == _h - 1 || c == _w - 1 || (r >= 35 && c >= 50) ? 100 : 0,
];

List<double?> _ranges(Pose2D at) => [
  for (var i = 0; i < 180; i++)
    () {
      final a = at.yaw + i * 2 * math.pi / 180;
      for (var d = 0.05; d < 10; d += _res / 4) {
        final c = ((at.x + d * math.cos(a)) / _res).floor(), r = ((at.y + d * math.sin(a)) / _res).floor();
        if (c < 0 || r < 0 || c >= _w || r >= _h) return null;
        if (_cells[r * _w + c] == 100) return d;
      }
      return null;
    }(),
];

RobotTools _tools(TopicRobot robot, {RobotLog? log, PlaceBook? places, List<String> nodes = const ['/amcl'],
    List<(String, String)> topics = const [], Future<Directory> Function()? mapFolder}) {
  robot.serviceResponses['/rosapi/topics'] = {
    'topics': [for (final t in topics) t.$1], 'types': [for (final t in topics) t.$2]};
  robot.serviceResponses['/rosapi/nodes'] = {'nodes': nodes};
  return RobotTools(ros: RosClient(robot), connection: robot,
      capabilities: () => RobotCapabilities.discover(robot), log: log, places: places, mapFolder: mapFolder);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('check_robot reports the battery and the log\'s recent problems', () async {
    final robot = TopicRobot()..topics['/battery_state'] = [
      {'voltage': 11.1, 'current': -0.5, 'percentage': 0.18, 'power_supply_status': 2}];
    addTearDown(robot.close);
    final log = RobotLog(RosClient(robot))
      ..add({'stamp': {'sec': DateTime.now().millisecondsSinceEpoch ~/ 1000, 'nanosec': 0}, 'level': 40,
        'name': 'planner_server', 'msg': 'GridBased: failed to create plan'});
    final tools = _tools(robot, log: log, topics: [('/battery_state', 'sensor_msgs/msg/BatteryState')]);
    await tools.refresh();
    expect(tools.abilities.battery, '/battery_state');
    final r = await tools.checkRobot();
    expect(r.ok, isTrue);
    expect(r.message, contains('Battery: 18 %'));
    expect(r.message, contains('1 error'));
    expect(r.message, contains('planner_server'));
    expect(r.data['errors'], ['planner_server: GridBased: failed to create plan']);
  });

  test('save_place stores where the robot is on the map', () async {
    final robot = TopicRobot()..topics['/tf'] = [{'transforms': [
      _tf('map', 'odom', 1, 0), _tf('odom', 'base_footprint', 0.5, 0.25, math.pi / 2)]}];
    addTearDown(robot.close);
    final places = PlaceBook('robot:9090');
    final tools = _tools(robot, places: places, topics: [('/map', 'nav_msgs/msg/OccupancyGrid')]);
    await tools.refresh();
    expect(tools.abilities.savePlace, isTrue);
    final r = await tools.savePlace('부엌');
    expect(r.ok, isTrue, reason: r.message);
    final p = places.find('부엌');
    expect(p, isNotNull);
    expect(p!.x, closeTo(1.5, 1e-9));
    expect(p.y, closeTo(0.25, 1e-9));
    expect(p.yaw, closeTo(math.pi / 2, 1e-9));
    // A second name for the same spot is saved too, with a note (seen on the emulator: 부엌 and kitchen).
    final again = await tools.savePlace('kitchen');
    expect(again.ok, isTrue);
    expect(again.message, contains('"부엌" is saved at almost the same spot'));
  });

  test('find_position matches the laser to the map and sets the pose; a poor fit sets nothing', () async {
    const truth = Pose2D(1.2, 0.9, 0.7);
    final robot = TopicRobot()
      ..topics['/map'] = [{
        'header': {'frame_id': 'map'},
        'info': {'width': _w, 'height': _h, 'resolution': _res, 'origin': {
          'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
        'data': _cells,
      }]
      ..topics['/scan'] = [{'header': {'frame_id': 'base_scan'}, 'angle_min': 0.0,
        'angle_increment': 2 * math.pi / 180, 'range_min': 0.04, 'range_max': 10.0, 'ranges': _ranges(truth)}]
      // The robot wrongly believes it is at (2.5, 0.5).
      ..topics['/tf'] = [{'transforms': [_tf('map', 'odom', 0, 0), _tf('odom', 'base_footprint', 2.5, 0.5, math.pi)]}]
      ..topics['/tf_static'] = [{'transforms': [_tf('base_footprint', 'base_scan', 0, 0)]}];
    addTearDown(robot.close);
    final tools = _tools(robot, nodes: ['/amcl'],
        topics: [('/map', 'nav_msgs/msg/OccupancyGrid'), ('/scan', 'sensor_msgs/msg/LaserScan')]);
    await tools.refresh();
    expect(tools.abilities.localize, isTrue);
    final r = await tools.findPosition();
    expect(r.ok, isTrue, reason: r.message);
    expect(r.message, contains('off)'), reason: 'it says how far off the old estimate was');
    final sent = robot.sent.lastWhere((m) => m['op'] == 'publish' && m['topic'] == '/initialpose');
    final pos = sent['msg']['pose']['pose']['position'];
    expect(Pose2D((pos['x'] as num).toDouble(), (pos['y'] as num).toDouble(), 0).distanceTo(truth), lessThan(0.1));

    // A scan from somewhere that is not this room: nothing is published.
    robot.sent.clear();
    robot.topics['/scan'] = [{'header': {'frame_id': 'base_scan'}, 'angle_min': 0.0,
      'angle_increment': 2 * math.pi / 180, 'range_min': 0.04, 'range_max': 10.0,
      'ranges': [for (var i = 0; i < 180; i++) 0.7]}];
    final poor = await tools.findPosition();
    expect(poor.ok, isFalse);
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/initialpose'), isEmpty);
  });

  test('save_map saves through the robot\'s map saver and keeps a phone copy', () async {
    final robot = TopicRobot()
      ..topics['/map'] = [{'header': {'frame_id': 'map'}, 'info': {'width': 2, 'height': 2, 'resolution': 0.5,
        'origin': {'position': {'x': 0.0, 'y': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
        'data': [0, 100, -1, 0]}];
    robot.serviceResponses['/rosapi/services'] = {'services': ['/map_saver/save_map']};
    robot.serviceResponses['/map_saver/save_map'] = {'result': true};
    addTearDown(robot.close);
    final folder = Directory.systemTemp.createTempSync('maps');
    addTearDown(() => folder.deleteSync(recursive: true));
    final tools = _tools(robot, nodes: ['/slam_toolbox', '/map_saver'], mapFolder: () async => folder,
        topics: [('/map', 'nav_msgs/msg/OccupancyGrid')]);
    await tools.refresh();
    expect(tools.abilities.saveMap, isTrue);
    final r = await tools.saveMap('first floor');
    expect(r.ok, isTrue, reason: r.message);
    expect(r.message, 'Saved the map as "first_floor" on the robot and on this phone.');
    expect(utf8.decode(File('${folder.path}/first_floor.yaml').readAsBytesSync()), contains('first_floor.pgm'));
  });

  test('the new skills are offered only when the robot supports them, and the small model can call them', () {
    final none = AgentManifest.build();
    expect(none.skill('check_robot'), isNull);
    final m = AgentManifest.build(abilities: const RobotAbilities(localize: true, savePlace: true, battery: '/b'));
    expect(m.skill('check_robot'), isNotNull);
    expect(m.skill('find_position'), isNotNull);
    expect(m.skill('save_place'), isNotNull);
    expect(m.skill('save_map'), isNull, reason: 'not mapping');
    expect(m.describe(), contains('reports its battery'));
    final grammar = skillGrammar(m);
    expect(grammar, contains('c-check-robot'));
    expect(grammar, contains('c-save-place'));
    final prompt = localSystemPrompt(m);
    expect(prompt, contains('여기를 부엌으로 저장해'));
    final plan = parseLocalAnswer('{"say": "저장할게요.", "calls": [{"skill": "save_place", "name": "부엌"}]}');
    expect(plan.calls.single.args, {'name': '부엌'});
    expect(reportSkills, contains('check_robot'));
  });

  test('an English request gets an English sentence even when the small model answers in Korean', () async {
    final m = AgentManifest.build(abilities: const RobotAbilities(savePlace: true));
    final backend = LocalBackend(_Answers(['{"say": "여기를 front door로 저장할게요.", "calls": [{"skill": "save_place", "name": "front door"}]}']));
    final plan = await backend.plan(AgentRequest(instruction: 'remember this spot as front door', manifest: m, status: const {}));
    expect(plan.reply, 'Saving this spot as front door.');
    expect(plan.calls.single.args['name'], 'front door', reason: 'the call is kept as is');
    final korean = LocalBackend(_Answers(['{"say": "여기를 부엌으로 저장할게요.", "calls": [{"skill": "save_place", "name": "부엌"}]}']));
    final kept = await korean.plan(AgentRequest(instruction: '여기를 부엌으로 저장해', manifest: m, status: const {}));
    expect(kept.reply, '여기를 부엌으로 저장할게요.');
    expect(planSentence(const [SkillCall('rotate', {'angle_deg': -90.0}), SkillCall('move', {'distance_m': 0.5})],
        ReplyLanguage.en), 'Turning right 90°, then driving forward 0.5 m.');
    expect(planSentence(const [SkillCall('rotate', {'angle_deg': 45.0}), SkillCall('go_to_place', {'name': '부엌'})],
        ReplyLanguage.ko), '왼쪽으로 45° 돌고, 부엌으로 갈게요.');
  });

  test('two saved places named but only one planned: handed on, not half done', () async {
    final nav = NavigationController(RosClient(FakeConnection()))
      ..configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose');
    addTearDown(nav.dispose);
    final m = AgentManifest.build(profile: RobotProfile.defaults(DriveType.differential), nav: nav,
      places: const [Place('kitchen', 3, 1), Place('charging dock', 0, 0)]);
    Future<LocalPlan> plan(String text, String answer) =>
        LocalBackend(_Answers([answer])).plan(AgentRequest(instruction: text, manifest: m, status: const {}));
    const one = '{"say": "Going to kitchen.", "calls": [{"skill": "go_to_place", "name": "kitchen"}]}';
    expect((await plan('go to the kitchen, then come back to the charging dock', one)).handoff, isTrue);
    final both = await plan('go to the kitchen, then come back to the charging dock',
      '{"say": "ok", "calls": [{"skill": "go_to_place", "name": "kitchen"}, {"skill": "go_to_place", "name": "charging dock"}]}');
    expect((both.handoff, both.calls.length), (false, 2));
    expect((await plan('go to the kitchen', one)).handoff, isFalse, reason: 'one place named, one planned');
    expect((await plan('부엌에 갔다가 충전 독으로 돌아와', one)).handoff, isTrue, reason: 'two stops in other words');
    expect((await plan('부엌으로 가', one)).handoff, isFalse);
  });

  test('replies in Japanese, Chinese and Spanish for requests in those languages', () {
    expect(replyLanguageFor('1メートル進んで'), ReplyLanguage.ja);
    expect(replyLanguageFor('前进一米'), ReplyLanguage.zh);
    expect(replyLanguageFor('avanza un metro'), ReplyLanguage.es);
    expect(replyLanguageFor("I've got it, go forward"), ReplyLanguage.en);
    expect(replyLanguageFor('앞으로 가'), ReplyLanguage.ko);
    const calls = [SkillCall('rotate', {'angle_deg': -90.0}), SkillCall('move', {'distance_m': 1.0})];
    expect(planSentence(calls, ReplyLanguage.ja), '右に90°回転し、1 m 前進します。');
    expect(planSentence(calls, ReplyLanguage.zh), '我将向右转 90°，然后前进 1 米。');
    expect(planSentence(calls, ReplyLanguage.es), 'Giro 90° a la derecha y luego avanzo 1 m.');
    expect(cannotDo(ReplyLanguage.ja), 'このロボットにはそれはできません。');
    // Beyond the screens' languages: motion in the request's language, the rest in English words.
    for (final (text, want) in [
      ('fahr 30 cm zurück und dreh nach links', 'Fahre 0.3 m zurück, dann drehe mich 90° nach links.'),
      ('recule de 30 cm et tourne à gauche', 'Je recule de 0.3 m, puis je tourne de 90° à gauche.'),
      ('lùi lại 30 cm rồi rẽ trái', 'Lùi 0.3 m, rồi rẽ trái 90°.'),
      ('ถอยหลัง 30 เซนติเมตรแล้วเลี้ยวซ้าย', 'ถอยหลัง 0.3 เมตร แล้วเลี้ยวซ้าย 90 องศา'),
      ('mundur 30 cm lalu belok kiri', 'Mundur 0.3 m, lalu belok kiri 90°.'),
      ('отъедь назад на 30 см и повернись налево', 'Еду назад на 0.3 м, затем поворачиваю налево на 90°.'),
      ('ارجع 30 سنتيمتر ثم استدر يسارا', 'أرجع 0.3 م ثم أستدير يسارًا 90°.'),
    ]) {
      expect(planSentence(const [SkillCall('move', {'distance_m': -0.3}), SkillCall('rotate', {'angle_deg': 90.0})],
          replyLanguageFor(text)), want, reason: text);
    }
    expect(replyLanguageFor('go back 30 cm'), ReplyLanguage.en);
    expect(lacking('This robot cannot move sideways.', ReplyLanguage.es), 'Este robot no puede moverse de lado.');
  });

  test('a name to save is kept as the person said it, never translated or invented', () async {
    final m = AgentManifest.build(abilities: const RobotAbilities(savePlace: true, saveMap: true));
    Future<LocalPlan> plan(String instruction, String answer) =>
        LocalBackend(_Answers([answer])).plan(AgentRequest(instruction: instruction, manifest: m, status: const {}));
    // Seen on the emulator: "kitchen" saved as "부엌" after the Korean example.
    final translated = await plan('Save this spot as kitchen',
        '{"say": "Saving.", "calls": [{"skill": "save_place", "name": "부엌"}]}');
    expect(translated.calls.single.args['name'], 'kitchen');
    // A bare "Save" made a place called "저장": nothing is saved, the person is asked for a name.
    final invented = await plan('Save', '{"say": "Saving.", "calls": [{"skill": "save_place", "name": "저장"}]}');
    expect(invented.calls, isEmpty);
    expect(invented.reply, contains('What name'));
    // A map name may be left out instead (it gets a dated one).
    final map = await plan('save the map', '{"say": "Saving.", "calls": [{"skill": "save_map", "name": "지도"}]}');
    expect(map.calls.single.args.containsKey('name'), isFalse);
    // Correct names pass untouched.
    final ok = await plan('여기를 부엌으로 저장해', '{"say": "저장할게요.", "calls": [{"skill": "save_place", "name": "부엌"}]}');
    expect(ok.calls.single.args['name'], '부엌');
    expect(nameFromInstruction('remember this spot as "front door"'), 'front door');
    expect(nameFromInstruction('call it garage.'), 'garage');
    expect(nameFromInstruction('아침순찰이라고 저장해'), '아침순찰');
    expect(nameFromInstruction('여기를 거실로 기억해'), '거실');
  });

  test('the agent runs a new skill through the tools, after validating it', () async {
    final robot = TopicRobot();
    addTearDown(robot.close);
    final tools = _tools(robot, log: RobotLog(RosClient(robot)));
    final session = _FakeSessionParts(robot);
    final agent = RobotAgent(drive: session.drive, nav: session.nav, backend: _Once([const SkillCall('check_robot')]),
        tools: tools);
    final run = await agent.handle('배터리 얼마야?');
    expect(run.results.single.ok, isTrue, reason: run.results.single.message);
    expect(run.results.single.message, contains('does not report its battery'));
  });
}

class _Answers extends LocalModel {
  _Answers(this.answers);
  final List<String> answers;
  var _i = 0;
  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) async => answers[_i++ % answers.length];
}

class _Once extends AgentBackend {
  _Once(this.calls);
  final List<SkillCall> calls;
  @override
  String get name => 'once';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls);
}

class _FakeSessionParts {
  _FakeSessionParts(TopicRobot robot) : ros = RosClient(robot);
  final RosClient ros;
  late final drive = DriveController(ros);
  late final nav = NavigationController(ros);
}
