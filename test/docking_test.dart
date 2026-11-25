import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/docking.dart';
import 'package:ros_tester/ros_client.dart';
import 'support/fake_ros_connection.dart';

void main() {
  late FakeConnection robot;
  late DockController dock;

  setUp(() {
    robot = FakeConnection();
    dock = DockController(RosClient(robot))..configure(['/navigate_to_pose', '/dock_robot', '/undock_robot']);
  });
  tearDown(() => dock.dispose());

  Iterable<Map<String, dynamic>> goals() => robot.sent.where((m) => m['op'] == 'send_action_goal');
  void result(String id, Map<String, Object?> values, {int status = 4}) =>
      robot.events.add({'op': 'action_result', 'id': id, 'status': status, 'result': true, 'values': values});

  test('the docking server is the robot\'s own: namespaced, or none', () {
    expect((dock.canDock, dock.canUndock), (true, true));
    final other = DockController(RosClient(robot))
      ..configure(['/robot1/dock_robot', '/robot2/dock_robot', '/robot2/undock_robot'], namespace: '/robot2');
    expect((other.canDock, other.canUndock), (true, true));
    other.configure(['/robot1/dock_robot'], namespace: '/robot2');
    expect(other.available, isFalse);
    dock.configure(['/navigate_to_pose']);
    expect(dock.available, isFalse);
    other.dispose();
  });

  test('docking sends the dock id and follows the stages; it ends docked', () async {
    final done = dock.dockAt(' home_dock ');
    expect(dock.status, DockStatus.docking);
    final goal = goals().single;
    expect(goal['action'], '/dock_robot');
    expect(goal['action_type'], 'nav2_msgs/action/DockRobot');
    expect(goal['args']['use_dock_id'], isTrue);
    expect(goal['args']['dock_id'], 'home_dock');
    expect(goal['args']['navigate_to_staging_pose'], isTrue);
    robot.events.add({'op': 'action_feedback', 'id': goal['id'], 'values': {'state': 3, 'num_retries': 1}});
    await pumpEventQueue();
    expect((dock.stage, dock.retries), (DockStage.controlling, 1));
    result(goal['id'] as String, {'success': true, 'error_code': 0, 'num_retries': 1, 'error_msg': ''});
    expect(await done, DockStatus.docked);
    expect(dock.dockId, 'home_dock');
  });

  test('a failure carries Nav2\'s error code and sentence', () async {
    final done = dock.dockAt('home_dock');
    result(goals().single['id'] as String,
        {'success': false, 'error_code': 904, 'num_retries': 3, 'error_msg': 'no dock'}, status: 6);
    expect(await done, DockStatus.failed);
    expect(dock.errorCode, 904);
    expect(dock.detail, contains('could not see the dock'));
    dock.reset();
    expect((dock.status, dock.errorCode), (DockStatus.idle, null));
  });

  test('"success: false" in a finished goal is still a failure (undocking)', () async {
    final done = dock.undock();
    final goal = goals().single;
    expect(goal['action'], '/undock_robot');
    result(goal['id'] as String, {'success': false, 'error_code': 905, 'error_msg': ''});
    expect(await done, DockStatus.failed);
    expect(dock.errorCode, 905);
  });

  test('undocking succeeds; cancelling stops at once and the robot\'s answer changes nothing', () async {
    var done = dock.undock();
    result(goals().last['id'] as String, {'success': true, 'error_code': 0, 'error_msg': ''});
    expect(await done, DockStatus.undocked);

    done = dock.dockAt('home_dock');
    dock.cancel();
    expect(await done, DockStatus.canceled);
    expect(robot.sent.where((m) => m['op'] == 'cancel_action_goal'), isNotEmpty);
    result(goals().last['id'] as String, {'success': false, 'error_code': 0}, status: 5);
    await pumpEventQueue();
    expect(dock.status, DockStatus.canceled);
  });

  test('a dock name is required; without a docking server nothing is sent', () {
    expect(() => dock.dockAt('  '), throwsArgumentError);
    dock.configure([]);
    expect(() => dock.dockAt('home_dock'), throwsStateError);
    expect(() => dock.undock(), throwsStateError);
    expect(goals(), isEmpty);
  });
}
