// Live check of the app's Zenoh connection against a robot on rmw_zenoh (e.g. scripts/ros2_jazzy_sim.sh
// with RMW_IMPLEMENTATION=rmw_zenoh_cpp), with no rosbridge involved. Needs the native library
// (native/zenoh/build_windows.ps1 on a PC). Not part of `flutter test`; run explicitly:
//   flutter test tool/live_zenoh_test.dart [--dart-define=ROUTER=192.168.0.10]
// ignore_for_file: avoid_print -- progress output is the point of this manual check
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/drone.dart' show yawOf;
import 'package:ros_tester/zenoh/zenoh_connection.dart';
import 'dds_test_support.dart';

const router = String.fromEnvironment('ROUTER', defaultValue: '127.0.0.1');

void main() {
  late ZenohRosSession session;
  late ZenohRosConnection ros;

  setUpAll(() async {
    final watch = Stopwatch()..start();
    session = await ZenohRosSession.open(router: router, interfaces: bundledInterfaces());
    ros = session.connect();
    print('connected to $router in ${watch.elapsedMilliseconds} ms; '
        '${session.graph.entities.length} graph entities, nodes: ${session.graph.nodeNames.length}');
  });
  tearDownAll(() => session.close());

  Future<Map<String, dynamic>> next(String topic, {Duration timeout = const Duration(seconds: 10)}) =>
      ros.messages.firstWhere((m) => m['op'] == 'publish' && m['topic'] == topic).timeout(timeout);

  test('rosapi from the Zenoh graph', () async {
    final topics = await ros.call('/rosapi/topics');
    final names = topics['topics'] as List;
    print('topics: ${names.length}, actions: ${(await ros.call('/rosapi/action_servers'))['action_servers']}');
    expect(names, containsAll(['/odom', '/scan', '/map', '/cmd_vel']));
    expect((await ros.call('/rosapi/nodes'))['nodes'], contains('/amcl'));
  });

  test('odometry, LiDAR and the latched map arrive', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    ros.send({'op': 'subscribe', 'topic': '/scan', 'throttle_rate': 200});
    final odom = await next('/odom');
    final scan = await next('/scan');
    print('odom at x=${(odom['msg']['pose']['pose']['position']['x'] as num).toStringAsFixed(2)}, '
        'scan ${(scan['msg']['ranges'] as List).length} ranges');
    ros.send({'op': 'subscribe', 'topic': '/map'});
    final map = await next('/map', timeout: const Duration(seconds: 15));
    print('map ${map['msg']['info']['width']}x${map['msg']['info']['height']} (latched, from the publisher cache)');
    expect((map['msg']['data'] as List).length, (map['msg']['info']['width'] as int) * (map['msg']['info']['height'] as int));
  });

  test('publishing /cmd_vel turns the robot', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    final start = yawOf((await next('/odom'))['msg']['pose']['pose']['orientation'] as Map);
    ros.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
    for (var i = 0; i < 20; i++) { // 2 s at 0.5 rad/s
      ros.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {'angular': {'z': 0.5}}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    ros.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {}});
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final end = yawOf((await next('/odom'))['msg']['pose']['pose']['orientation'] as Map);
    final turned = math.atan2(math.sin(end - start), math.cos(end - start)) * 180 / math.pi;
    print('turned ${turned.toStringAsFixed(1)}° from /cmd_vel over Zenoh');
    expect(turned, greaterThan(30));
  });

  test('a service call', () async {
    final state = await ros.call('/map_server/get_state');
    print('map_server state: ${state['current_state']['label']}');
    expect(state['current_state']['label'], 'active');
  });

  test('a Nav2 goal with feedback and result', () async {
    final events = <Map<String, dynamic>>[];
    final sub = ros.messages.listen(events.add);
    ros.send({'op': 'send_action_goal', 'id': 'z1', 'action': '/navigate_to_pose',
      'action_type': 'nav2_msgs/action/NavigateToPose', 'feedback': true,
      'args': {'pose': {'header': {'frame_id': 'map'}, 'pose': {'position': {'x': -1.0, 'y': -0.5},
        'orientation': {'w': 1.0}}}, 'behavior_tree': ''}});
    final result = await ros.messages
        .firstWhere((m) => m['op'] == 'action_result' && m['id'] == 'z1')
        .timeout(const Duration(seconds: 90));
    await sub.cancel();
    final feedback = events.where((m) => m['op'] == 'action_feedback').length;
    print('nav result: status ${result['status']} (${result['result']}), $feedback feedback messages');
    expect(result['result'], isTrue, reason: '${result['values']}');
    expect(result['status'], 4);
    expect(feedback, greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
