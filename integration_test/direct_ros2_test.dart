// On-device check of the direct ROS 2 connection against the TurtleBot3 + Nav2 simulation
// (scripts/ros2_sim.sh), with no rosbridge involved. Phone and PC on the same Wi-Fi:
//   flutter test integration_test/direct_ros2_test.dart -d <device> --dart-define=ROBOT=<pc ip>
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ros_tester/dds/direct_connection.dart';
import 'package:ros_tester/ros_connection.dart';

const robot = String.fromEnvironment('ROBOT');

Future<Map<String, dynamic>> firstMessage(RosConnection ros, String topic, {Duration limit = const Duration(seconds: 10)}) =>
    ros.messages.firstWhere((m) => m['op'] == 'publish' && m['topic'] == topic).timeout(limit).then((m) => m['msg'] as Map<String, dynamic>);

double yawOf(Map q) {
  final x = (q['x'] as num).toDouble(), y = (q['y'] as num).toDouble(), z = (q['z'] as num).toDouble(), w = (q['w'] as num).toDouble();
  return math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('direct ROS 2 connection drives the simulated TurtleBot3', (tester) async {
    final watch = Stopwatch()..start();
    final session = await DirectRosSession.open(robot: robot, domain: 0, discoveryTimeout: const Duration(seconds: 12));
    final ros = session.connect(ownsSession: true);
    addTearDown(ros.close);
    debugPrint('discovery: ${watch.elapsedMilliseconds} ms, ${session.graph.participants.length} participants, '
        '${session.graph.endpoints.length} endpoints, complete=${session.discoveryComplete}');

    final topics = await ros.call('/rosapi/topics');
    expect(topics['topics'], containsAll(['/odom', '/cmd_vel', '/map', '/scan', '/tf']));
    debugPrint('topics: ${(topics['topics'] as List).length}');
    await Future<void>.delayed(const Duration(seconds: 1)); // ros_discovery_info
    final nodes = (await ros.call('/rosapi/nodes'))['nodes'] as List;
    debugPrint('nodes: ${nodes.length} e.g. ${nodes.take(6).join(', ')}');
    expect(nodes, contains('/bt_navigator'));
    final odomPublishers = (await ros.call('/rosapi/publishers', {'topic': '/odom'}))['publishers'];
    debugPrint('/odom publishers: $odomPublishers');
    expect(odomPublishers, isNotEmpty);

    // /odom in, /cmd_vel out: turn in place and watch the yaw change.
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    final before = await firstMessage(ros, '/odom');
    final yaw0 = yawOf(before['pose']['pose']['orientation'] as Map);
    var odomCount = 0;
    final counting = ros.messages.where((m) => m['topic'] == '/odom').listen((_) => odomCount++);
    ros.send({'op': 'advertise', 'topic': '/cmd_vel', 'type': 'geometry_msgs/msg/Twist'});
    for (var i = 0; i < 30; i++) {
      ros.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {'linear': {'x': 0.0}, 'angular': {'z': 0.6}}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (var i = 0; i < 5; i++) {
      ros.send({'op': 'publish', 'topic': '/cmd_vel', 'msg': {'linear': {'x': 0.0}, 'angular': {'z': 0.0}}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final after = await firstMessage(ros, '/odom');
    await counting.cancel();
    var turned = (yawOf(after['pose']['pose']['orientation'] as Map) - yaw0) * 180 / math.pi;
    turned = (turned + 540) % 360 - 180;
    debugPrint('turned ${turned.toStringAsFixed(1)} deg (0.6 rad/s for 3 s = 103 deg), $odomCount odom msgs in ~3.9 s');
    expect(turned.abs(), greaterThan(40));

    // Latched map (transient local) and a LiDAR scan.
    ros.send({'op': 'subscribe', 'topic': '/map'});
    final map = await firstMessage(ros, '/map');
    debugPrint('map: ${map['info']['width']}x${map['info']['height']} @ ${map['info']['resolution']} m, '
        '${(map['data'] as List).length} cells');
    expect((map['data'] as List).length, (map['info']['width'] as int) * (map['info']['height'] as int));
    ros.send({'op': 'subscribe', 'topic': '/scan'});
    final scan = await firstMessage(ros, '/scan');
    debugPrint('scan: ${(scan['ranges'] as List).length} ranges, frame ${scan['header']['frame_id']}');

    // A real service call (Fast DDS server in the default Humble setup).
    final state = await ros.call('/map_server/get_state');
    debugPrint('/map_server/get_state -> $state');
    expect(state['current_state']['label'], 'active');

    // Message definitions for the publish form.
    final details = await ros.call('/rosapi/message_details', {'type': 'geometry_msgs/msg/PoseStamped'});
    expect((details['typedefs'] as List).first['type'], 'geometry_msgs/PoseStamped');

    // Nav2: NavigateToPose to a free spot 1 m away (two known-free poses of the TB3 world). Much shorter
    // goals can leave this Nav2 setup looping "Reached the goal" without finishing, whoever sends them.
    ros.send({'op': 'subscribe', 'topic': '/amcl_pose'});
    final amcl = await firstMessage(ros, '/amcl_pose', limit: const Duration(seconds: 15));
    final pose = amcl['pose']['pose'] as Map;
    final gx = -2.0, gy = (pose['position']['y'] as num) < 0 ? 0.5 : -0.5;
    debugPrint('amcl ${(pose['position']['x'] as num).toStringAsFixed(2)}, ${(pose['position']['y'] as num).toStringAsFixed(2)} '
        '-> goal ${gx.toStringAsFixed(2)}, ${gy.toStringAsFixed(2)}');
    var feedbacks = 0;
    double? remaining;
    final fb = ros.messages.where((m) => m['op'] == 'action_feedback').listen((m) {
      feedbacks++;
      remaining = (m['values']['distance_remaining'] as num?)?.toDouble();
    });
    final trace = ros.messages.where((m) => m['op'] == 'status' || m['op'] == 'action_result')
        .listen((m) => debugPrint('action trace: $m'));
    final result = ros.messages.firstWhere((m) => m['op'] == 'action_result');
    ros.send({'op': 'send_action_goal', 'id': 'goal-1', 'action': '/navigate_to_pose',
      'action_type': 'nav2_msgs/action/NavigateToPose', 'feedback': true, 'args': {
        'pose': {'header': {'frame_id': 'map'}, 'pose': {'position': {'x': gx, 'y': gy}, 'orientation': {'w': 1.0}}},
      }});
    // This Nav2 setup sometimes circles "Aborting handle" right next to the goal and never finishes,
    // whoever sent it. Then cancel, which must end the goal with status CANCELED (5).
    Map<String, dynamic> r;
    try {
      r = await result.timeout(const Duration(seconds: 60));
    } on TimeoutException {
      debugPrint('nav2: no result after 60 s, cancelling');
      ros.send({'op': 'cancel_action_goal', 'id': 'goal-1', 'action': '/navigate_to_pose'});
      r = await result.timeout(const Duration(seconds: 20));
      expect(r['status'], 5);
    }
    await fb.cancel();
    await trace.cancel();
    debugPrint('nav2 result: result=${r['result']} status=${r['status']} values=${r['values']}, '
        '$feedbacks feedback msgs (last distance_remaining $remaining)');
    expect(r['result'], isTrue);
    expect(feedbacks, greaterThan(0));
    debugPrint('total ${watch.elapsed.inSeconds} s');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
