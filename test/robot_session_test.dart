import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'support/fake_ros_connection.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  FakeConnection robot() => FakeConnection()
    ..serviceResponses.addAll({
      '/rosapi/topics': {
        'topics': ['/cmd_vel', '/odom', '/goal_pose'],
        'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'geometry_msgs/msg/PoseStamped'],
      },
      '/rosapi/action_servers': {'action_servers': ['/navigate_to_pose']},
    });

  test('prepare points drive and nav at the robot once, without any screen', () async {
    final connection = robot();
    final session = RobotSession(connection: connection, ip: 'robot', port: '9090');
    expect(connection.sent, isEmpty, reason: 'nothing is advertised on connect');

    await session.prepare();
    expect(session.drive.profile?.drive, DriveType.differential);
    expect(session.drive.profile?.commandTopic, '/cmd_vel');
    expect(session.nav.configured, isTrue);
    expect(session.nav.mode, NavMode.action);
    final ads = connection.sent.where((m) => m['op'] == 'advertise').length;

    await session.prepare();
    expect(connection.sent.where((m) => m['op'] == 'advertise').length, ads, reason: 'second prepare is a no-op');

    session.dispose();
    expect(connection.sent.where((m) => m['op'] == 'unadvertise').map((m) => m['topic']), contains('/cmd_vel'));
  });

  test('a saved robot profile wins over the suggestion', () async {
    final saved = RobotProfile.defaults(DriveType.holonomic, commandTopic: '/base/cmd_vel');
    await ProfileStore.save('robot', '9090', saved);
    final session = RobotSession(connection: robot(), ip: 'robot', port: '9090');
    await session.prepare();
    expect(session.drive.profile?.drive, DriveType.holonomic);
    expect(session.drive.profile?.commandTopic, '/base/cmd_vel');
    session.dispose();
  });

  test('a screen that configured drive first is not overridden', () async {
    final session = RobotSession(connection: robot(), ip: 'robot', port: '9090');
    final chosen = RobotProfile.defaults(DriveType.ackermann);
    session.drive.configure(chosen, session.nav.version);
    await session.prepare();
    expect(session.drive.profile, same(chosen));
    session.dispose();
  });
}
