import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/navigation_goal.dart';

void main() {
  test('ROS version comes from rosapi type naming, defaulting to ROS 2', () {
    expect(detectRosVersion(null), RosVersion.ros2);
    expect(detectRosVersion({}), RosVersion.ros2);
    expect(detectRosVersion({'types': []}), RosVersion.ros2);
    expect(detectRosVersion({'types': ['nav_msgs/msg/OccupancyGrid', 'rcl_interfaces/msg/Log']}), RosVersion.ros2);
    expect(detectRosVersion({'types': ['nav_msgs/OccupancyGrid', 'rosgraph_msgs/Log']}), RosVersion.ros1);
  });

  test('ROS 2 goal is a PoseStamped with sec/nanosec and no seq', () {
    final msg = goalMessage(RosVersion.ros2, 'map', 1.5, -2, 'id');
    expect(msg.keys, unorderedEquals(['header', 'pose']));
    expect(msg['header'], {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': 'map'});
    expect(msg['pose']['position'], {'x': 1.5, 'y': -2.0, 'z': 0.0});
    expect(msg['pose']['orientation']['w'], 1.0);
  });

  test('ROS 1 goal is a MoveBaseActionGoal with secs/nsecs and a goal id', () {
    final msg = goalMessage(RosVersion.ros1, 'map', 1.5, -2, 'goal-7');
    expect(msg['header']['stamp'], {'secs': 0, 'nsecs': 0});
    expect(msg['goal_id']['id'], 'goal-7');
    expect(msg['goal']['target_pose']['header']['frame_id'], 'map');
    expect(msg['goal']['target_pose']['pose']['position'], {'x': 1.5, 'y': -2.0, 'z': 0.0});
  });

  test('goal channels match each navigation stack', () {
    expect(goalChannel(RosVersion.ros2).topic, '/goal_pose');
    expect(goalChannel(RosVersion.ros2).type, 'geometry_msgs/msg/PoseStamped');
    expect(goalChannel(RosVersion.ros1).topic, '/move_base/goal');
    expect(goalChannel(RosVersion.ros1).type, 'move_base_msgs/MoveBaseActionGoal');
  });
}
