// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Diagnostics against a real ROS 2 graph: rosbridge (or foxglove_bridge) and a node publishing
// /diagnostics (OK, WARN, and an ERROR after /diag_fail). See the comments in the publisher script.
// flutter test tool/live_diagnostics_test.dart [--dart-define=PORT=9090 --dart-define=VIA=foxglove]
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/diagnostics.dart';
import 'package:ros_tester/foxglove_connection.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('PORT', defaultValue: '9090');
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live: levels, names and values arrive as published', () async {
    final RosConnection c = via == 'foxglove' ? await FoxgloveRosConnection.connect(host, port) : RosConnection(host, port);
    addTearDown(c.close);
    await c.ready;
    final topics = await c.call('/rosapi/topics');
    final names = List<String>.from(topics['topics'] as List);
    final types = List<String>.from(topics['types'] as List);
    final topic = pickDiagnosticsTopic({for (var i = 0; i < names.length; i++) names[i]: types[i]});
    print('via $via: diagnostics topic $topic');
    expect(topic, '/diagnostics');
    final board = DiagnosticsBoard();
    final alerts = DiagnosticsAlerts();
    final announced = <String>[];
    Object? rawLevel;
    c.messages.listen((e) {
      if (e['op'] != 'publish' || e['topic'] != topic) return;
      rawLevel ??= ((e['msg'] as Map)['status'] as List).first['level'];
      announced.addAll(alerts.newErrors(board.update(e['msg'], DateTime.now())).map((s) => s.name));
    });
    c.send({'op': 'subscribe', 'id': 'live-diag', 'topic': topic, 'throttle_rate': 0, 'queue_length': 1});
    await Future<void>.delayed(const Duration(seconds: 4));
    print('raw level as sent by the bridge: ${rawLevel.runtimeType} $rawLevel');
    for (final s in board.sorted(DateTime.now())) {
      print('  ${s.name}: ${s.level.name} "${s.message}" ${s.values}');
    }
    final byName = {for (final s in board.sorted(DateTime.now())) s.name: s};
    expect(byName['base: motors']!.level, DiagLevel.ok);
    expect(byName['base: battery']!.level, DiagLevel.warn);
    expect(byName['base: battery']!.values, contains(('voltage', '10.9')));
    expect(byName['lidar: scan rate']!.level, DiagLevel.ok);
    expect(announced, isEmpty);

    c.send({'op': 'advertise', 'topic': '/diag_fail', 'type': 'std_msgs/msg/Empty'});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (var i = 0; i < 3; i++) {
      c.send({'op': 'publish', 'topic': '/diag_fail', 'msg': <String, Object?>{}});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await Future<void>.delayed(const Duration(seconds: 3));
    print('after /diag_fail: announced $announced');
    expect(announced, ['lidar: scan rate'], reason: 'one notice, not one per second');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
