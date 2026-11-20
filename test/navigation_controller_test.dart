import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  late FakeConnection robot;
  late NavigationController nav;
  setUp(() {
    robot = FakeConnection();
    nav = NavigationController(RosClient(robot));
  });
  tearDown(() => nav.dispose());

  Iterable<Map<String, dynamic>> sent(String op) => robot.sent.where((m) => m['op'] == op);

  group('action mode', () {
    setUp(() => nav.configure(version: RosVersion.ros2, navigateAction: '/navigate_to_pose'));

    test('sends NavigateToPose, follows feedback and completes with the result', () async {
      expect(nav.mode, NavMode.action);
      expect(nav.label, 'Nav2 · navigate_to_pose');
      expect(sent('advertise'), isEmpty, reason: 'action mode publishes nothing');

      final done = nav.goTo(const Pose2D(2, 1, 0), from: const Pose2D(0, 1, 0));
      final goal = sent('send_action_goal').single;
      expect(goal['action'], '/navigate_to_pose');
      expect(goal['args']['pose']['pose']['position']['x'], 2.0);
      expect(nav.status, NavStatus.active);
      expect(nav.distanceRemaining, 2.0);

      robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {
        'distance_remaining': 3.0, 'estimated_time_remaining': {'sec': 7, 'nanosec': 500000000},
        'number_of_recoveries': 1}});
      await pumpEventQueue();
      expect(nav.distanceRemaining, 3.0);
      expect(nav.startDistance, 3.0, reason: 'path length may exceed the straight line');
      expect(nav.etaSeconds, 7.5);
      expect(nav.recoveries, 1);

      robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 4, 'result': true, 'values': {}});
      expect(await done, NavStatus.succeeded);
      expect(nav.status, NavStatus.succeeded);
    });

    test('an abort after motion preserves the actual Nav2 error instead of assuming no path', () async {
      final done = nav.goTo(const Pose2D(1, 1, 0), from: const Pose2D(0, 0, 0));
      final id = sent('send_action_goal').single['id'];
      robot.events.add({'op': 'action_feedback', 'id': id, 'values': {'distance_remaining': 0.2}});
      await pumpEventQueue();
      robot.events.add({'op': 'action_result', 'id': id, 'status': 6, 'result': true,
        'values': {'error_code': 9002, 'error_msg': 'Timed out waiting for map to base_link transform'}});
      expect(await done, NavStatus.failed);
      expect(nav.detail, contains('Timed out waiting for map to base_link transform'));
      expect(nav.detail, isNot(contains('no valid path')));
    });

    test('a goal rosbridge itself failed to send is sent once more; a second failure stands', () async {
      const glitch = "send_action_goal to '/navigate_to_pose' failed: Object of type 'NoneType' is not an instance of 'capsule'";
      final done = nav.goTo(const Pose2D(1, 1, 0));
      final first = sent('send_action_goal').single['id'];
      robot.events.add({'op': 'status', 'level': 'error', 'id': first, 'msg': glitch});
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final again = sent('send_action_goal').toList();
      expect(again, hasLength(2));
      expect(again.last['args']['pose']['pose']['position']['x'], 1.0);
      expect(nav.status, NavStatus.active);
      robot.events.add({'op': 'action_result', 'id': again.last['id'], 'status': 4, 'result': true, 'values': {}});
      expect(await done, NavStatus.succeeded);

      final next = nav.goTo(const Pose2D(2, 2, 0));
      for (var i = 0; i < 2; i++) {
        robot.events.add({'op': 'status', 'level': 'error', 'id': sent('send_action_goal').last['id'], 'msg': glitch});
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
      expect(await next, NavStatus.failed);
      expect(sent('send_action_goal'), hasLength(4), reason: 'one retry per goal');
    });

    test('aborted goals fail with an explanation', () async {
      final done = nav.goTo(const Pose2D(1, 1, 0));
      final id = sent('send_action_goal').single['id'];
      robot.events.add({'op': 'action_result', 'id': id, 'status': 6, 'result': true});
      expect(await done, NavStatus.failed);
      expect(nav.detail, NavigationController.abortedDetail);
    });

    test('cancel sends cancel_action_goal and ignores the later result', () async {
      final done = nav.goTo(const Pose2D(1, 1, 0));
      final id = sent('send_action_goal').single['id'];
      nav.cancel();
      expect(sent('cancel_action_goal').single['id'], id);
      expect(await done, NavStatus.canceled);
      robot.events.add({'op': 'action_result', 'id': id, 'status': 4, 'result': true});
      await pumpEventQueue();
      expect(nav.status, NavStatus.canceled);
    });

    test('a new goal supersedes the running one', () async {
      final first = nav.goTo(const Pose2D(1, 1, 0));
      final firstId = sent('send_action_goal').single['id'];
      final second = nav.goTo(const Pose2D(2, 2, 0));
      expect(await first, NavStatus.canceled);
      robot.events.add({'op': 'action_result', 'id': firstId, 'status': 6, 'result': true});
      await pumpEventQueue();
      expect(nav.status, NavStatus.active, reason: 'the old goal result does not end the new one');
      final secondId = sent('send_action_goal').last['id'];
      robot.events.add({'op': 'action_result', 'id': secondId, 'status': 4, 'result': true});
      expect(await second, NavStatus.succeeded);
    });
  });

  group('goal topic mode', () {
    setUp(() => nav.configure(version: RosVersion.ros2));

    test('publishes on /goal_pose and arrives by position', () async {
      expect(nav.mode, NavMode.goalPose);
      expect(sent('advertise').single['topic'], '/goal_pose');
      final done = nav.goTo(const Pose2D(1, 1, 0));
      final goal = sent('publish').single;
      expect(goal['topic'], '/goal_pose');
      expect(goal['msg']['header']['frame_id'], 'map');

      nav.updateRobotPose(const Pose2D(0, 1, 0));
      expect(nav.distanceRemaining, 1.0);
      nav.updateRobotPose(const Pose2D(0.9, 1, 0));
      expect(await done, NavStatus.succeeded);
      expect(nav.detail, contains('0.3 m'));
    });

    test('cancel calls the NavigateToPose cancel service', () async {
      final done = nav.goTo(const Pose2D(1, 1, 0));
      nav.cancel();
      expect(sent('call_service').single['service'], '/navigate_to_pose/_action/cancel_goal');
      expect(await done, NavStatus.canceled);
    });

    test('switching to action mode withdraws the goal topic', () {
      nav.configure(version: RosVersion.ros2, navigateAction: '/robot1/navigate_to_pose');
      expect(sent('unadvertise').single['topic'], '/goal_pose');
      expect(nav.label, 'Nav2 · /robot1/navigate_to_pose');
    });
  });

  test('ROS 1 move_base: goal and cancel topics', () async {
    nav.configure(version: RosVersion.ros1, moveBaseAction: '/move_base');
    expect(nav.mode, NavMode.moveBase);
    expect(sent('advertise').map((m) => m['topic']), ['/move_base/goal', '/move_base/cancel']);
    final done = nav.goTo(const Pose2D(1, 1, 0));
    nav.cancel();
    expect(sent('publish').last['topic'], '/move_base/cancel');
    expect(await done, NavStatus.canceled);
  });

  test('reset clears a finished goal but not a running one', () async {
    nav.configure(version: RosVersion.ros2);
    nav.goTo(const Pose2D(1, 1, 0));
    nav.reset();
    expect(nav.status, NavStatus.active);
    nav.cancel();
    nav.reset();
    expect(nav.status, NavStatus.idle);
    expect(nav.goal, isNull);
  });

  test('dispose withdraws topics and releases waiters without cancelling on the robot', () async {
    final local = NavigationController(RosClient(robot))..configure(version: RosVersion.ros2);
    final done = local.goTo(const Pose2D(1, 1, 0));
    local.dispose();
    expect(await done, NavStatus.failed);
    expect(sent('unadvertise').single['topic'], '/goal_pose');
    expect(sent('call_service'), isEmpty);
  });
}
