import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/routines_page.dart' show NoPlanner;
import 'support/fake_ros_connection.dart';

/// Found on a car-like robot in Gazebo with no map and no Nav2: the assistant was still offered
/// navigate_to, because navigation fell back to the conventional /goal_pose.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<List<String>> skillsFor(Map<String, String> topics, {List<String> actions = const []}) async {
    final robot = FakeConnection();
    robot.serviceResponses
      ..['/rosapi/topics'] = {'topics': topics.keys.toList(), 'types': topics.values.toList()}
      ..['/rosapi/action_servers'] = {'action_servers': actions};
    final session = RobotSession(connection: robot, ip: 'pc', port: '9090');
    addTearDown(session.dispose);
    await session.prepare();
    final agent = RobotAgent.forSession(session, NoPlanner());
    addTearDown(agent.dispose);
    return [for (final s in agent.manifest().skills) s.name];
  }

  const base = {'/cmd_vel': 'geometry_msgs/msg/Twist', '/odom': 'nav_msgs/msg/Odometry'};

  test('no navigation stack: the assistant gets no navigation skills', () async {
    final skills = await skillsFor(base);
    expect(skills, contains('move'));
    expect(skills, isNot(contains('navigate_to')));
    expect(skills, isNot(contains('cancel_navigation')));
  });

  test('a drone is never offered map navigation, whatever PoseStamped topics MAVROS has', () async {
    // Found on PX4 SITL: /mavros/setpoint_position/local was taken for a navigation goal topic.
    final skills = await skillsFor({
      '/mavros/setpoint_velocity/cmd_vel_unstamped': 'geometry_msgs/msg/Twist',
      '/mavros/state': 'mavros_msgs/msg/State',
      '/mavros/setpoint_position/local': 'geometry_msgs/msg/PoseStamped',
      '/mavros/local_position/odom': 'nav_msgs/msg/Odometry',
    });
    expect(skills, isNot(contains('navigate_to')));
    expect(skills, isNot(contains('move')));
    expect(await skillsFor({...base, '/some/target_pose': 'geometry_msgs/msg/PoseStamped'}),
        isNot(contains('navigate_to')), reason: 'not every PoseStamped topic is a navigation goal');
  });

  test('a Nav2 action server or a goal topic: navigation is offered', () async {
    expect(await skillsFor(base, actions: ['/navigate_to_pose']), contains('navigate_to'));
    expect(await skillsFor({...base, '/goal_pose': 'geometry_msgs/msg/PoseStamped'}), contains('navigate_to'));
  });
}
