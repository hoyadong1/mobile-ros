import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_identity.dart';
import 'package:ros_tester/robot_persona.dart';

import 'support/fake_ros_connection.dart';

const turtleNodes = ['/turtlebot3_node', '/robot_state_publisher', '/amcl', '/rosbridge_websocket', '/rosapi',
  '/mobile_ros_phone', '/_ros2cli_daemon_0'];

FakeConnection turtle() => FakeConnection()
  ..serviceResponses['/rosapi/topics'] = {
    'topics': ['/cmd_vel', '/odom', '/scan'],
    'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/LaserScan']}
  ..serviceResponses['/rosapi/nodes'] = {'nodes': turtleNodes};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the fingerprint is the robot\'s own nodes, not tools or connections', () {
    expect(RobotIdentity.fingerprint(turtleNodes), '/amcl,/robot_state_publisher,/turtlebot3_node');
    expect(RobotIdentity.fingerprint(['/rosbridge_websocket', '/rosapi', '/talker']), '', reason: 'too little to tell');
  });

  test('a link makes the new address use the robot\'s saved key; "different" is not asked again', () async {
    final id = await RobotIdentity.load();
    await id.remember('10.0.0.5:9090', fingerprint: 'a,b,c', label: 'TurtleBot3', address: '10.0.0.5:9090');
    final match = id.match('a,b,c', '10.0.0.9:9090');
    expect(match?.storeKey, '10.0.0.5:9090');
    await id.link('10.0.0.9:9090', '10.0.0.5:9090');
    final again = await RobotIdentity.load();
    expect(again.storeKeyFor('10.0.0.9:9090'), '10.0.0.5:9090');
    expect(again.match('a,b,c', '10.0.0.9:9090'), isNull, reason: 'already that robot');
    await again.markDistinct('10.0.0.7:9090', '10.0.0.5:9090');
    expect(again.match('a,b,c', '10.0.0.7:9090'), isNull);
  });

  testWidgets('the same robot at a new address keeps its name and memory once the person confirms', (tester) async {
    // First seen at .5, named.
    final first = turtle();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: '10.0.0.5', port: '9090', connection: first)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('same-robot-dialog')), findsNothing, reason: 'nothing to compare with yet');
    final memory = Memory(Memory.robotScope('10.0.0.5:9090'));
    await tester.runAsync(() => memory.setProfile(RobotPersona.nameKey, '순돌이'));
    await tester.pumpWidget(const SizedBox());
    first.close();

    // The router gave it another address.
    final second = turtle();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: '10.0.0.9', port: '9090', connection: second)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('same-robot-dialog')), findsOneWidget);
    expect(find.text('Is this 순돌이?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('same-robot-yes')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('순돌이'), findsWidgets, reason: 'its name is back (the workspace title)');
    expect((await tester.runAsync(RobotIdentity.load))!.storeKeyFor('10.0.0.9:9090'), '10.0.0.5:9090');
    await tester.pumpWidget(const SizedBox());
    second.close();

    // Next time at .9: no question, straight to the same robot.
    final third = turtle();
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: '10.0.0.9', port: '9090', connection: third)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('same-robot-dialog')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    third.close();
  });
}
