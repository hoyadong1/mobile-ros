// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Topic health against a real ROS 2 graph. On the robot (or a ROS 2 WSL distro), run rosbridge (or
// foxglove_bridge) and three publishers:
//   /imu_live     noisy IMU at 50 Hz                          → OK
//   /scan_frozen  lidar at 10 Hz, fresh stamps, same ranges    → Frozen
//   /scan_stops   noisy lidar at 10 Hz until /health_stop      → OK, then Stopped
// then: flutter test tool/live_topic_health_test.dart [--dart-define=HOST=.. --dart-define=PORT=9090
//       --dart-define=VIA=foxglove]
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/foxglove_connection.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:ros_tester/topic_health.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('PORT', defaultValue: '9090');
const via = String.fromEnvironment('VIA', defaultValue: 'rosbridge');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('live: OK, frozen and stopped topics are told apart', () async {
    final RosConnection c = via == 'foxglove' ? await FoxgloveRosConnection.connect(host, port) : RosConnection(host, port);
    addTearDown(c.close);
    await c.ready;
    final topics = await c.call('/rosapi/topics');
    final names = List<String>.from(topics['topics'] as List);
    final types = List<String>.from(topics['types'] as List);
    final typeOf = {for (var i = 0; i < names.length; i++) names[i]: types[i]};
    print('via $via; picked by default: ${pickHealthTopics(typeOf)}');
    final watched = ['/imu_live', '/scan_frozen', '/scan_stops'];
    final health = {for (final t in watched) t: TopicHealth(t, typeOf[t] ?? '')};
    c.messages.listen((e) {
      if (e['op'] == 'publish') health[e['topic']]?.onMessage(e['msg'], DateTime.now());
    });
    for (final t in watched) {
      c.send({'op': 'subscribe', 'id': 'live-$t', 'topic': t, 'throttle_rate': 0, 'queue_length': 1});
    }
    Future<void> run(int seconds) async {
      for (var i = 0; i < seconds; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
        for (final h in health.values) {
          h.tick(DateTime.now());
        }
      }
    }
    void report(String when) {
      final now = DateTime.now();
      for (final h in health.values) {
        print('$when ${h.topic}: ${h.condition(now).name}, ${h.rate(now).toStringAsFixed(1)} Hz '
            '(usual ${h.usualRate?.toStringAsFixed(1)}), received ${h.received}');
      }
    }
    await run(10);
    report('after 10 s:');
    final now = DateTime.now();
    expect(health['/imu_live']!.condition(now), TopicCondition.ok);
    expect(health['/imu_live']!.usualRate, closeTo(50, 10));
    expect(health['/scan_frozen']!.condition(now), TopicCondition.frozen);
    expect(health['/scan_stops']!.condition(now), TopicCondition.ok);

    c.send({'op': 'advertise', 'topic': '/health_stop', 'type': 'std_msgs/msg/Empty'});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    for (var i = 0; i < 3; i++) {
      c.send({'op': 'publish', 'topic': '/health_stop', 'msg': <String, Object?>{}});
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await run(5);
    report('5 s after stopping /scan_stops:');
    final later = DateTime.now();
    expect(health['/scan_stops']!.condition(later), TopicCondition.stale);
    expect(health['/imu_live']!.condition(later), TopicCondition.ok);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
