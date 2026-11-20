import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/control_page.dart';
import 'package:ros_tester/disconnect_safety.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

const topics = {
  'topics': ['/cmd_vel', '/odom'],
  'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry'],
};

Future<FakeConnection> _open(WidgetTester tester, {List<String> nodes = const ['/turtlebot3_diff_drive']}) async {
  final robot = FakeConnection()
    ..serviceResponses['/rosapi/topics'] = topics
    ..serviceResponses['/rosapi/nodes'] = {'nodes': nodes};
  final camera = FakeConnection();
  addTearDown(camera.close);
  await tester.binding.setSurfaceSize(const Size(900, 420));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(home: ControlScreen(
    ip: 'robot', port: '9090', channel: robot, imageConnectionFactory: (_, _) => camera)));
  await tester.pump();
  await tester.pump();
  if (find.byKey(const Key('profile-continue')).evaluate().isNotEmpty) {
    await tester.tap(find.byKey(const Key('profile-continue'))); // accept the suggested differential drive
    await tester.pump();
    await tester.pump();
  }
  return robot;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('recognises what stops a base when commands stop arriving', () {
    expect(stopOnLinkLossGuard(nodes: ['/turtlebot3_diff_drive'], topics: ['/cmd_vel']), isNull);
    expect(stopOnLinkLossGuard(nodes: ['/cmd_vel_watchdog'], topics: ['/cmd_vel']), 'cmd_vel watchdog');
    expect(stopOnLinkLossGuard(nodes: ['/robot1/twist_mux'], topics: []), 'twist_mux');
    expect(stopOnLinkLossGuard(nodes: ['/controller_manager'], topics: ['/diff_drive_controller/cmd_vel_unstamped']),
        'ros2_control drive controller');
    expect(stopOnLinkLossGuard(nodes: ['/controller_manager'], topics: ['/joint_states']), isNull);
  });

  test('a link lost within two seconds of a motion command counts as lost while moving', () {
    final now = DateTime(2026, 11, 14, 12);
    expect(lostWhileMoving(lastMotion: null, movingNow: false, now: now), isFalse);
    expect(lostWhileMoving(lastMotion: null, movingNow: true, now: now), isTrue);
    expect(lostWhileMoving(lastMotion: now.subtract(const Duration(milliseconds: 1500)), movingNow: false, now: now), isTrue);
    expect(lostWhileMoving(lastMotion: now.subtract(const Duration(seconds: 5)), movingNow: false, now: now), isFalse);
  });

  testWidgets('a robot with no known stop-on-timeout gets a one-time notice', (tester) async {
    final robot = await _open(tester);
    expect(find.byKey(const Key('link-loss-notice')), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-loss-notice')));
    await tester.pump(const Duration(milliseconds: 400)); // the camera keeps animating: no settle
    expect(find.text('If the connection drops'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('link-loss-notice')), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('link_loss_notice_seen:robot:9090'), isTrue);
    robot.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('no notice when the robot runs a watchdog', (tester) async {
    final robot = await _open(tester, nodes: ['/turtlebot3_diff_drive', '/cmd_vel_watchdog']);
    expect(find.byKey(const Key('link-loss-notice')), findsNothing);
    robot.close();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('losing the link mid-drive shows a loud warning; while parked a plain message', (tester) async {
    var robot = await _open(tester);
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('stick-left'))));
    for (var i = 0; i < 5; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 250));
    expect(robot.sent.where((m) => m['op'] == 'publish' && m['topic'] == '/cmd_vel'), isNotEmpty);
    robot.close(); // link drops while the stick is still pushed
    await tester.pump();
    expect(find.byKey(const Key('link-lost-warning')), findsOneWidget);
    expect(find.text(linkLostWhileMoving), findsOneWidget);
    await gesture.up();
    await tester.pumpWidget(const SizedBox());

    robot = await _open(tester);
    await tester.pump(const Duration(seconds: 3));
    robot.close();
    await tester.pump();
    expect(find.byKey(const Key('link-lost-warning')), findsNothing);
    expect(find.text('Robot disconnected. Control unavailable.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
