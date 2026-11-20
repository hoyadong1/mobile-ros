import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/fleet_overview_page.dart';
import 'package:ros_tester/robot_session.dart';

import 'support/fake_ros_connection.dart';

void main() {
  testWidgets('fleet shows both states and both map-frame poses on one map', (tester) async {
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': [
        '/map', '/robot1/cmd_vel', '/robot1/odom', '/robot1/amcl_pose', '/robot1/battery_state',
        '/robot2/cmd_vel', '/robot2/odom', '/robot2/amcl_pose', '/robot2/battery_state',
      ],
      'types': [
        'nav_msgs/msg/OccupancyGrid', 'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/PoseWithCovarianceStamped', 'sensor_msgs/msg/BatteryState',
        'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry',
        'geometry_msgs/msg/PoseWithCovarianceStamped', 'sensor_msgs/msg/BatteryState',
      ],
    };
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    await tester.pumpWidget(MaterialApp(home: FleetOverviewPage(sessions: sessions)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(connection.sent.where((m) => m['op'] == 'subscribe').length, 5);
    expect(connection.sent.where((m) => m['op'] == 'subscribe').map((m) => m['topic']),
      containsAll(['/robot1/battery_state', '/robot2/battery_state']));
    connection.events.add({'op': 'publish', 'topic': '/map', 'msg': {
      'header': {'frame_id': 'map'}, 'info': {'width': 2, 'height': 2, 'resolution': 1,
        'origin': {'position': {'x': 0, 'y': 0}, 'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1}}},
      'data': [0, 0, 0, 0],
    }});
    for (final (i, name) in ['robot1', 'robot2'].indexed) {
      connection.events.add({'op': 'publish', 'topic': '/$name/amcl_pose', 'msg': {
        'header': {'frame_id': 'map'}, 'pose': {'pose': {
          'position': {'x': i, 'y': i}, 'orientation': {'x': 0, 'y': 0, 'z': 0, 'w': 1},
        }},
      }});
      connection.events.add({'op': 'publish', 'topic': '/$name/battery_state',
        'msg': {'percentage': (i + 1) / 4}});
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('fleet-robot1')), findsOneWidget);
    expect(find.byKey(const Key('fleet-robot2')), findsOneWidget);
    expect(find.text('Battery: 25%'), findsOneWidget);
    expect(find.text('Battery: 50%'), findsOneWidget);
    expect(find.text('Position: 0.0, 0.0 m'), findsOneWidget);
    expect(find.text('Position: 1.0, 1.0 m'), findsOneWidget);
    expect(find.byKey(const Key('fleet-map')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });

  testWidgets('a robot whose pose topic appears after the screen opens is picked up', (tester) async {
    const types = {'/map': 'nav_msgs/msg/OccupancyGrid', '/robot1/cmd_vel': 'geometry_msgs/msg/Twist',
      '/robot1/odom': 'nav_msgs/msg/Odometry', '/robot1/amcl_pose': 'geometry_msgs/msg/PoseWithCovarianceStamped',
      '/robot2/cmd_vel': 'geometry_msgs/msg/Twist', '/robot2/odom': 'nav_msgs/msg/Odometry'};
    Map<String, Object> topics(Map<String, String> t) => {'topics': t.keys.toList(), 'types': t.values.toList()};
    // A direct connection still learning the graph: robot2's localization is not known yet.
    final connection = FakeConnection()..serviceResponses['/rosapi/topics'] = topics(types);
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    await tester.pumpWidget(MaterialApp(home: FleetOverviewPage(sessions: sessions)));
    await tester.pump(const Duration(milliseconds: 100));
    List<Object?> subscribed() => [for (final m in connection.sent) if (m['op'] == 'subscribe') m['topic']];
    expect(subscribed(), containsAll(['/map', '/robot1/amcl_pose']));
    expect(subscribed(), isNot(contains('/robot2/amcl_pose')));

    connection.serviceResponses['/rosapi/topics'] =
        topics({...types, '/robot2/amcl_pose': 'geometry_msgs/msg/PoseWithCovarianceStamped'});
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(subscribed().where((t) => t == '/robot2/amcl_pose'), hasLength(1));
    expect(subscribed().where((t) => t == '/robot1/amcl_pose'), hasLength(1), reason: 'not subscribed twice');
    expect(subscribed().where((t) => t == '/map'), hasLength(1));

    // Everything found: no more looking.
    final asked = connection.sent.length;
    await tester.pump(const Duration(seconds: 10));
    expect(connection.sent.length, asked);
    await tester.pumpWidget(const SizedBox());
    for (final session in sessions) { session.dispose(); }
    connection.close();
  });
}
