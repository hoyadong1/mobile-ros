import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/patrol.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  late FakeConnection robot;
  late PatrolController patrol;
  final stops = [
    const PatrolStop('door', Pose2D(1, 0, 0)),
    const PatrolStop('desk', Pose2D(2, 1, 1.5707963)),
    const PatrolStop('kitchen', Pose2D(0, 2, 3.14159)),
  ];

  setUp(() {
    robot = FakeConnection();
    patrol = PatrolController(RosClient(robot))..configure(['/navigate_to_pose', '/follow_waypoints']);
  });
  tearDown(() => patrol.dispose());

  Iterable<Map<String, dynamic>> goals() => robot.sent.where((m) => m['op'] == 'send_action_goal');
  void finish(String id, {int status = 4, List<int> missed = const []}) =>
      robot.events.add({'op': 'action_result', 'id': id, 'status': status, 'result': true,
        'values': {'missed_waypoints': missed}});

  test('the action server is the robot\'s own: namespaced, or none', () {
    expect(patrol.action, '/follow_waypoints');
    final other = PatrolController(RosClient(robot))
      ..configure(['/robot1/follow_waypoints', '/robot2/follow_waypoints'], namespace: '/robot2');
    expect(other.action, '/robot2/follow_waypoints');
    other.configure(['/robot1/follow_waypoints', '/robot2/follow_waypoints'], namespace: '/robot3');
    expect(other.available, isFalse);
    other.configure(['/navigate_to_pose']);
    expect(other.available, isFalse);
    other.dispose();
  });

  test('the goal carries every place as a stamped pose in the map frame', () {
    final args = followWaypointsArgs(stops);
    final poses = args['poses'] as List;
    expect(poses, hasLength(3));
    expect(poses[1]['header']['frame_id'], 'map');
    expect(poses[1]['pose']['position'], {'x': 2.0, 'y': 1.0, 'z': 0.0});
    expect(poses[1]['pose']['orientation']['z'], closeTo(0.7071, 1e-3));
  });

  test('a round: progress follows the feedback, and it ends finished with the places it missed', () async {
    final done = patrol.start(stops);
    expect(patrol.isRunning, isTrue);
    final goal = goals().single;
    expect(goal['action'], '/follow_waypoints');
    expect(goal['action_type'], 'nav2_msgs/action/FollowWaypoints');
    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {'current_waypoint': 2}});
    await pumpEventQueue();
    expect((patrol.current, patrol.currentName), (2, 'kitchen'));
    finish(goal['id'] as String, missed: [1]);
    expect(await done, PatrolStatus.finished);
    expect(patrol.missed, {1});
    expect(patrol.laps, 1);
  });

  test('looping sends the round again until cancelled', () async {
    final done = patrol.start(stops, loop: true);
    finish(goals().first['id'] as String);
    await pumpEventQueue();
    expect(goals(), hasLength(2), reason: 'a second round');
    expect(patrol.laps, 1);
    expect(patrol.isRunning, isTrue);
    patrol.cancel();
    expect(await done, PatrolStatus.canceled);
    expect(robot.sent.where((m) => m['op'] == 'cancel_action_goal'), isNotEmpty);
    finish(goals().last['id'] as String, status: 5); // the robot's answer to the cancel changes nothing
    await pumpEventQueue();
    expect(patrol.status, PatrolStatus.canceled);
    expect(goals(), hasLength(2));
  });

  test('Nav2 reaching none of the places is a failure; an abort fails with the reason', () async {
    var done = patrol.start(stops);
    finish(goals().last['id'] as String, missed: [0, 1, 2]);
    expect(await done, PatrolStatus.failed);
    done = patrol.start(stops);
    finish(goals().last['id'] as String, status: 6);
    expect(await done, PatrolStatus.failed);
    expect(patrol.detail, isNotNull);
  });

  test('fewer than two places, or no action server, is refused', () {
    expect(() => patrol.start(stops.take(1).toList()), throwsArgumentError);
    patrol.configure([]);
    expect(() => patrol.start(stops), throwsStateError);
  });

  test('starting again replaces the round: the old one ends cancelled and its result is ignored', () async {
    final first = patrol.start(stops);
    final firstId = goals().first['id'] as String;
    final second = patrol.start(stops.reversed.toList());
    expect(await first, PatrolStatus.canceled);
    finish(firstId);
    await pumpEventQueue();
    expect(patrol.isRunning, isTrue, reason: 'the old goal\'s result is not the new round\'s');
    finish(goals().last['id'] as String);
    expect(await second, PatrolStatus.finished);
  });
}
