import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/incident_recorder.dart';
import 'package:ros_tester/incidents_page.dart';
import 'package:ros_tester/mcap_writer.dart';
import 'package:ros_tester/topic_health.dart';
import 'package:ros_tester/topic_health_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Map<String, Object?> stampOf(DateTime t) =>
    {'sec': t.microsecondsSinceEpoch ~/ 1000000, 'nanosec': (t.microsecondsSinceEpoch % 1000000) * 1000};

Map<String, Object?> scan(DateTime t, double range) => {
  'header': {'stamp': stampOf(t), 'frame_id': 'base_scan'},
  'ranges': [range, range + 0.01, range + 0.02],
};

/// Feeds [h] at [hz] for [seconds] from [start]; returns the time after the last message.
DateTime feed(TopicHealth h, DateTime start, double hz, double seconds,
    {Object? Function(int i, DateTime t)? message}) {
  var t = start;
  final step = Duration(microseconds: (1e6 / hz).round());
  final n = (seconds * hz).round();
  for (var i = 0; i < n; i++) {
    h.onMessage(message?.call(i, t) ?? scan(t, 1 + (i % 7) * 0.003), t);
    if (i % hz.ceil() == 0) h.tick(t);
    t = t.add(step);
  }
  h.tick(t);
  return t;
}

void main() {
  final t0 = DateTime(2026, 11, 24, 10);

  test('a steady sensor is OK; its usual rate is learned', () {
    final h = TopicHealth('/scan', 'sensor_msgs/msg/LaserScan');
    expect(h.condition(t0), TopicCondition.waiting);
    final t = feed(h, t0, 10, 12);
    expect(h.condition(t), TopicCondition.ok);
    expect(h.usualRate, closeTo(10, 0.6));
    expect(h.rate(t), closeTo(10, 0.6));
  });

  test('a topic that stops is overdue after three usual gaps (at least 2 s)', () {
    final h = TopicHealth('/scan', 'sensor_msgs/LaserScan');
    final t = feed(h, t0, 10, 10);
    expect(h.condition(t.add(const Duration(milliseconds: 1500))), isNot(TopicCondition.stale));
    expect(h.condition(t.add(const Duration(seconds: 3))), TopicCondition.stale);
    for (var k = 1; k <= 4; k++) {
      h.tick(t.add(Duration(milliseconds: 500 * k)));
    }
    expect(h.usualRate, closeTo(10, 0.3), reason: 'the falling rate after it stopped is not learned');
  });

  test('a slow topic (well under half its usual rate) is flagged; a short dip is not learned as usual', () {
    final h = TopicHealth('/scan', 'sensor_msgs/LaserScan');
    var t = feed(h, t0, 10, 10);
    t = feed(h, t, 3, 6);
    expect(h.condition(t), TopicCondition.slow);
    expect(h.usualRate, greaterThan(8), reason: 'the dip did not drag the usual rate down');
  });

  test('a lidar sending the same values with fresh timestamps is frozen; odometry standing still is not', () {
    final h = TopicHealth('/scan', 'sensor_msgs/LaserScan');
    var t = feed(h, t0, 10, 5);
    t = feed(h, t, 10, 3, message: (i, t) => scan(t, 2.0));
    expect(h.condition(t), TopicCondition.frozen);
    expect(h.frozenFor(t), greaterThanOrEqualTo(const Duration(seconds: 2)));

    final odom = TopicHealth('/odom', 'nav_msgs/Odometry');
    final t2 = feed(odom, t0, 20, 8, message: (i, t) => {
      'header': {'stamp': stampOf(t)},
      'pose': {'pose': {'position': {'x': 1.0, 'y': 2.0, 'z': 0.0}}},
    });
    expect(odom.condition(t2), TopicCondition.ok);
  });

  test('timestamps that repeat or run backwards are flagged; zero stamps are ignored', () {
    final h = TopicHealth('/imu', 'sensor_msgs/Imu');
    final t = feed(h, t0, 50, 2, message: (i, t) => {
      'header': {'stamp': {'sec': 100, 'nanosec': 0}}, 'linear_acceleration': {'x': i * 0.001}});
    expect(h.condition(t), TopicCondition.badStamp);
    expect(h.stampWentBack, isFalse);

    final back = TopicHealth('/imu', 'sensor_msgs/Imu');
    var tb = feed(back, t0, 50, 2, message: (i, t) => {
      'header': {'stamp': {'sec': 100 + i, 'nanosec': 0}}, 'linear_acceleration': {'x': i * 0.001}});
    back.onMessage({'header': {'stamp': {'sec': 5, 'nanosec': 0}}, 'linear_acceleration': {'x': 9}}, tb);
    expect(back.condition(tb), TopicCondition.badStamp);
    expect(back.stampWentBack, isTrue);

    final zero = TopicHealth('/imu', 'sensor_msgs/Imu');
    tb = feed(zero, t0, 50, 2, message: (i, t) => {
      'header': {'stamp': {'sec': 0, 'nanosec': 0}}, 'linear_acceleration': {'x': i * 0.001}});
    expect(zero.condition(tb), TopicCondition.ok);
  });

  test('a one-shot topic (a map sent once) is never called overdue', () {
    final h = TopicHealth('/map', 'nav_msgs/OccupancyGrid');
    h.onMessage({'info': {}}, t0);
    h.tick(t0.add(const Duration(seconds: 10)));
    expect(h.condition(t0.add(const Duration(minutes: 5))), TopicCondition.ok);
  });

  test('default topics: sensors and state first, tf_static left out, at most 8', () {
    final picked = pickHealthTopics({
      '/cmd_vel': 'geometry_msgs/msg/Twist', '/odom': 'nav_msgs/msg/Odometry', '/scan': 'sensor_msgs/msg/LaserScan',
      '/tf': 'tf2_msgs/msg/TFMessage', '/tf_static': 'tf2_msgs/msg/TFMessage', '/imu': 'sensor_msgs/msg/Imu',
      '/battery_state': 'sensor_msgs/msg/BatteryState',
    });
    expect(picked, ['/scan', '/imu', '/odom', '/battery_state', '/tf']);
  });

  testWidgets('the page subscribes with its own ids, shows a stopped topic, and unsubscribes only its own',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var now = t0;
    final r = FakeConnection();
    addTearDown(r.close);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: TopicHealthPage(connection: r, clock: () => now, topicTypes: const {
      '/scan': 'sensor_msgs/msg/LaserScan', '/odom': 'nav_msgs/msg/Odometry', '/cmd_vel': 'geometry_msgs/msg/Twist'})));
    await tester.pump();
    final subs = r.sent.where((m) => m['op'] == 'subscribe').toList();
    expect(subs.map((m) => m['topic']), ['/scan', '/odom']);
    expect(subs.every((m) => m['id'] is String && m['throttle_rate'] == 0), isTrue);

    for (var i = 0; i < 80; i++) {
      r.events.add({'op': 'publish', 'topic': '/scan', 'msg': scan(t0.add(Duration(seconds: i)), 1 + (i % 5) * 0.01)});
      r.events.add({'op': 'publish', 'topic': '/odom', 'msg': {'header': {'stamp': {'sec': i, 'nanosec': 0}}}});
      now = now.add(const Duration(milliseconds: 100));
      if (i % 10 == 0) await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('All 2 topics look fine'), findsOneWidget);

    // The lidar stops; odometry keeps coming.
    for (var i = 0; i < 40; i++) {
      r.events.add({'op': 'publish', 'topic': '/odom', 'msg': {'header': {'stamp': {'sec': 100 + i, 'nanosec': 0}}}});
      now = now.add(const Duration(milliseconds: 100));
      if (i % 10 == 0) await tester.pump(const Duration(seconds: 1));
    }
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1 topic needs a look'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('health-state-/scan'))).data, 'Stopped');
    expect(tester.widget<Text>(find.byKey(const Key('health-state-/odom'))).data, 'OK');

    await tester.pumpWidget(const SizedBox());
    final unsubs = r.sent.where((m) => m['op'] == 'unsubscribe').toList();
    expect(unsubs.map((m) => m['id']), subs.map((m) => m['id']),
        reason: 'only this screen\'s subscriptions end; others on the same topic keep theirs');
  });

  test('an incident becomes a valid MCAP file: magic, records in order, Foxglove schemas, metadata', () {
    final events = [
      IncidentEvent(t0, IncidentKind.pose, '', x: 0, y: 0),
      IncidentEvent(t0.add(const Duration(seconds: 1)), IncidentKind.command, 'stick: forward', x: 0, y: 0),
      IncidentEvent(t0.add(const Duration(seconds: 2)), IncidentKind.pose, '', x: 0.5, y: 0.1),
      IncidentEvent(t0.add(const Duration(seconds: 3)), IncidentKind.log, 'controller: no valid path',
          x: 0.5, y: 0.1, level: 'error'),
    ];
    final bytes = incidentToMcap(Incident(robot: 'robot 1/ü', reason: 'Trip failed', time: t0, events: events));
    expect(bytes.sublist(0, 8), McapWriter.magic);
    expect(bytes.sublist(bytes.length - 8), McapWriter.magic);
    final d = ByteData.sublistView(bytes);
    final ops = <int>[];
    final texts = <String>[];
    var at = 8;
    while (at < bytes.length - 8) {
      final op = bytes[at];
      final len = d.getUint32(at + 1, Endian.little) + d.getUint32(at + 5, Endian.little) * 0x100000000;
      ops.add(op);
      texts.add(latin1.decode(bytes.sublist(at + 9, at + 9 + len), allowInvalid: true));
      at += 9 + len;
    }
    expect(at, bytes.length - 8, reason: 'record lengths add up exactly');
    expect(ops.first, 0x01, reason: 'header first');
    expect(ops.sublist(ops.length - 2), [0x0F, 0x02], reason: 'data end, then footer');
    expect(ops.where((o) => o == 0x03).length, 3);
    expect(ops.where((o) => o == 0x04).length, 3);
    expect(ops.where((o) => o == 0x05).length, 2 + 2 * 2, reason: 'two poses; two events each as log + event');
    expect(texts.any((t) => t.contains('foxglove.PoseInFrame')), isTrue);
    expect(texts.any((t) => t.contains('"level":4') && t.contains('no valid path')), isTrue);
    expect(texts.any((t) => t.contains('Trip failed')), isTrue);
    expect(incidentFileName(Incident(robot: 'robot 1/ü', reason: '', time: t0, events: const [])),
        'incident_robot_1_20261124_100000.mcap');
  });

  test('the MCAP writer output is read back by the reference reader when it is installed', () async {
    final python = Platform.environment['MCAP_PYTHON'];
    if (python == null) return; // optional cross-check: MCAP_PYTHON=<python with `pip install mcap`>
    final dir = await Directory.systemTemp.createTemp('mcap');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/i.mcap')..writeAsBytesSync(incidentToMcap(Incident(robot: 'r', reason: 'x', time: t0,
        events: [IncidentEvent(t0, IncidentKind.pose, '', x: 1, y: 2),
          IncidentEvent(t0, IncidentKind.notice, 'battery low', level: 'warning')])));
    final out = await Process.run(python, ['-c', '''
import sys
from mcap.reader import make_reader
r = make_reader(open(sys.argv[1], "rb"))
for schema, channel, message in r.iter_messages():
    print(channel.topic, schema.name, message.data.decode())
for m in r.iter_metadata():
    print("meta", m.name, dict(m.metadata))
''', file.path]);
    expect(out.exitCode, 0, reason: '${out.stderr}');
    expect('${out.stdout}', contains('/incident/pose foxglove.PoseInFrame'));
    expect('${out.stdout}', contains('/incident/log foxglove.Log'));
    expect('${out.stdout}', contains('meta incident'));
  });

  testWidgets('export saves an .mcap file through the save-as hook and says so', (tester) async {
    String? name;
    Uint8List? saved;
    await tester.pumpWidget(MaterialApp(home: IncidentPage(
      incident: Incident(robot: 'robot1', reason: 'Stuck', time: t0, events: [IncidentEvent(t0, IncidentKind.pose, '', x: 0, y: 0)]),
      saveFile: (n, b) async { name = n; saved = b; return true; })));
    await tester.tap(find.byKey(const Key('incident-export')));
    await tester.pumpAndSettle();
    expect(name, endsWith('.mcap'));
    expect(saved!.sublist(0, 8), McapWriter.magic);
    expect(find.textContaining('Saved the MCAP file'), findsOneWidget);
  });
}
