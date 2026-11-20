// ignore_for_file: avoid_print -- progress output is the point of this manual check
// The Foxglove connection against a real foxglove_bridge (ROS 2). On the robot (or a ROS 2 WSL distro):
//   ros2 launch foxglove_bridge foxglove_bridge_launch.xml port:=8765
//   ros2 run demo_nodes_cpp talker
//   ros2 run demo_nodes_cpp add_two_ints_server
//   ros2 topic echo /app_cmd geometry_msgs/msg/Twist      (shows what the app publishes)
// then: flutter test tool/live_foxglove_test.dart [--dart-define=HOST=127.0.0.1 --dart-define=PORT=8765]
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/foxglove_connection.dart';
import 'package:ros_tester/ros_client.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('PORT', defaultValue: '8765');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('topics, a subscription, publishing and a service through a real foxglove_bridge', () async {
    final connection = await FoxgloveRosConnection.connect(host, port);
    addTearDown(connection.close);
    print('capabilities: ${connection.capabilities}');
    final ros = RosClient(connection);

    final topics = await connection.call('/rosapi/topics');
    print('topics: ${topics['topics']}');
    expect(topics['topics'], contains('/chatter'));
    expect(topics['types'][(topics['topics'] as List).indexOf('/chatter')], 'std_msgs/msg/String');

    final said = await ros.subscribe('/chatter', type: 'std_msgs/msg/String').first.timeout(const Duration(seconds: 5));
    print('heard: ${said['data']}');
    expect('${said['data']}', startsWith('Hello World'));

    final services = (await connection.call('/rosapi/services'))['services'] as List;
    print('services: ${services.where((s) => '$s'.contains('add_two_ints')).toList()}');
    final sum = await connection.call('/add_two_ints', {'a': 2, 'b': 40});
    print('add_two_ints(2, 40) = ${sum['sum']}');
    expect(sum['sum'], 42);

    final publisher = ros.advertise('/app_cmd', 'geometry_msgs/msg/Twist');
    for (var i = 0; i < 10; i++) {
      publisher.publish({'linear': {'x': 0.25, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': -0.5}});
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    print('published 10 Twist messages on /app_cmd: check the echo on the robot');

    final nodes = (await connection.call('/rosapi/nodes'))['nodes'] as List;
    print('nodes: $nodes');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
