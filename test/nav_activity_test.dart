import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/controllers/navigation_controller.dart';
import 'package:ros_tester/map_geometry.dart';
import 'package:ros_tester/nav_activity.dart';
import 'package:ros_tester/navigation_goal.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

Map<String, Object?> log(List<(String, String)> changes) => {
  'event_log': [for (final (name, status) in changes)
    {'node_name': name, 'previous_status': 'IDLE', 'current_status': status}],
};

void main() {
  test('default Nav2 tree names map to activities; structural nodes to none', () {
    expect(activityOfNode('ComputePathToPose'), NavActivity.planning);
    expect(activityOfNode('FollowPath'), NavActivity.following);
    expect(activityOfNode('Spin'), NavActivity.spinning);
    expect(activityOfNode('BackUp'), NavActivity.backingUp);
    expect(activityOfNode('Wait'), NavActivity.waiting);
    expect(activityOfNode('DriveOnHeading'), NavActivity.drivingOnHeading);
    expect(activityOfNode('ClearLocalCostmap-Context'), NavActivity.clearing);
    expect(activityOfNode('ClearGlobalCostmap-Subtree'), NavActivity.clearing);
    for (final structural in ['NavigateRecovery', 'RecoveryActions', 'PipelineSequence', 'RateController',
      'GoalUpdated', 'ClearingActions', 'WouldAControllerRecoveryHelp', 'FollowWaypointsRecovery_x']) {
      expect(activityOfNode(structural), structural.startsWith('FollowWaypoints') ? NavActivity.following : null,
          reason: structural);
    }
    expect(behaviorTreeLogTopic('/navigate_to_pose'), '/behavior_tree_log');
    expect(behaviorTreeLogTopic('/robot1/navigate_to_pose'), '/robot1/behavior_tree_log');
  });

  test('the phase follows the trip; re-planning while following is not news; recoveries win and are counted', () {
    final t = NavActivityTracker();
    expect(t.onLog(log([('ComputePathToPose', 'RUNNING')])), isTrue);
    expect(t.current, NavActivity.planning);
    // Jazzy logs FollowPath only when it ends: a found route is what starts following.
    t.onLog(log([('ComputePathToPose', 'SUCCESS')]));
    expect(t.current, NavActivity.following);
    expect(t.onLog(log([('ComputePathToPose', 'RUNNING')])), isFalse, reason: 're-planning while following is not news');
    t.onLog(log([('ComputePathToPose', 'SUCCESS')]));
    expect(t.current, NavActivity.following);
    t.onLog(log([('FollowPath', 'FAILURE'), ('ClearLocalCostmap-Context', 'RUNNING')]));
    expect(t.current, NavActivity.clearing);
    t.onLog(log([('ClearLocalCostmap-Context', 'SUCCESS'), ('Spin', 'RUNNING')]));
    expect(t.current, NavActivity.spinning);
    t.onLog(log([('Spin', 'SUCCESS'), ('BackUp', 'RUNNING')]));
    expect(t.current, NavActivity.backingUp);
    expect(t.recoveryActions, 2, reason: 'clearing a costmap is not counted as a recovery action');
    t.onLog(log([('BackUp', 'SUCCESS')]));
    expect(t.current, NavActivity.planning, reason: 'after a recovery Nav2 plans again');
    t.onLog(log([('ComputePathToPose', 'RUNNING')]));
    t.onLog(log([('ComputePathToPose', 'FAILURE')]));
    expect(t.current, NavActivity.planning, reason: 'no route yet');
    t.onLog(log([('ComputePathToPose', 'RUNNING'), ('ComputePathToPose', 'SUCCESS')]));
    expect(t.current, NavActivity.following);
    expect(t.lastRecovery, NavActivity.backingUp, reason: 'kept for the stuck notice');
    t.reset();
    expect(t.current, isNull);
    expect(t.recoveryActions, 0);
  });

  test('a tree that does log FollowPath RUNNING works the same', () {
    final t = NavActivityTracker();
    t.onLog(log([('FollowPath', 'RUNNING')]));
    expect(t.current, NavActivity.following);
    t.onLog(log([('Wait', 'RUNNING')]));
    expect(t.current, NavActivity.waiting);
  });

  test('the controller follows the tree log during a goal and stops after it', () async {
    final robot = FakeConnection();
    final nav = NavigationController(RosClient(robot))
      ..configure(version: RosVersion.ros2, navigateAction: '/robot1/navigate_to_pose');
    addTearDown(nav.dispose);
    final done = nav.goTo(const Pose2D(2, 0, 0), from: const Pose2D(0, 0, 0));
    final sub = robot.sent.where((m) => m['op'] == 'subscribe').single;
    expect(sub['topic'], '/robot1/behavior_tree_log');
    expect(sub['type'], 'nav2_msgs/msg/BehaviorTreeLog');
    var changes = 0;
    nav.addListener(() => changes++);
    robot.events.add({'op': 'publish', 'topic': '/robot1/behavior_tree_log', 'msg': log([('Spin', 'RUNNING')])});
    await pumpEventQueue();
    expect(nav.activity, NavActivity.spinning);
    expect(changes, 1);
    final goal = robot.sent.where((m) => m['op'] == 'send_action_goal').single;
    robot.events.add({'op': 'action_result', 'id': goal['id'], 'status': 4, 'result': true, 'values': {}});
    expect(await done, NavStatus.succeeded);
    expect(nav.activity, isNull, reason: 'nothing is going on after the goal');
    await pumpEventQueue();
    expect(robot.sent.where((m) => m['op'] == 'unsubscribe').map((m) => m['topic']), contains('/robot1/behavior_tree_log'));
  });
}
