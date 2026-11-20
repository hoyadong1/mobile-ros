import 'dart:math' as math;

/// Navigation goal formats for ROS 2 Nav2 (default) and ROS 1 move_base.
enum RosVersion { ros1, ros2 }

/// rosapi reports ROS 2 types as `pkg/msg/Type` and ROS 1 types as `pkg/Type`.
/// Unknown (no rosapi answer) falls back to ROS 2, the current default.
RosVersion detectRosVersion(Map<String, dynamic>? topicsResponse) {
  final types = topicsResponse?['types'];
  if (types is! List || types.isEmpty) return RosVersion.ros2;
  return types.any((type) => '$type'.contains('/msg/')) ? RosVersion.ros2 : RosVersion.ros1;
}

class GoalChannel {
  final String topic;
  final String type;
  final String label;
  const GoalChannel(this.topic, this.type, this.label);
}

GoalChannel goalChannel(RosVersion version) => version == RosVersion.ros2
    ? const GoalChannel('/goal_pose', 'geometry_msgs/msg/PoseStamped', 'ROS 2 Nav2 (/goal_pose)')
    : const GoalChannel('/move_base/goal', 'move_base_msgs/MoveBaseActionGoal', 'ROS 1 move_base (/move_base/goal)');

/// A zero stamp tells the navigation stack to use the latest transform, which avoids
/// extrapolation errors when the phone clock differs from the robot (or simulation) clock.
Map<String, dynamic> goalMessage(RosVersion version, String frame, double x, double y, String goalId,
    {double yaw = 0}) {
  final pose = _pose(x, y, yaw);
  if (version == RosVersion.ros2) {
    return {'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': frame}, 'pose': pose};
  }
  final stamp = {'secs': 0, 'nsecs': 0};
  return {
    'header': {'seq': 0, 'stamp': stamp, 'frame_id': frame},
    'goal_id': {'stamp': stamp, 'id': goalId},
    'goal': {'target_pose': {'header': {'seq': 0, 'stamp': stamp, 'frame_id': frame}, 'pose': pose}},
  };
}

Map<String, dynamic> _pose(double x, double y, double yaw) => {
  'position': {'x': x, 'y': y, 'z': 0.0},
  'orientation': {'x': 0.0, 'y': 0.0, 'z': math.sin(yaw / 2), 'w': math.cos(yaw / 2)},
};

Map<String, dynamic> _stamp(RosVersion v) =>
    v == RosVersion.ros2 ? {'sec': 0, 'nanosec': 0} : {'secs': 0, 'nsecs': 0};

/// Nav2's NavigateToPose action (sent through rosbridge's send_action_goal): unlike publishing on
/// /goal_pose, it reports progress (feedback) and success/failure (result), and can be cancelled.
const navigateToPoseAction = '/navigate_to_pose';
const navigateToPoseType = 'nav2_msgs/action/NavigateToPose';

Map<String, dynamic> navigateToPoseArgs(String frame, double x, double y, double yaw) => {
  'pose': {'header': {'stamp': {'sec': 0, 'nanosec': 0}, 'frame_id': frame}, 'pose': _pose(x, y, yaw)},
  'behavior_tree': '',
};

/// action_msgs/GoalStatus codes reported by rosbridge with an action result.
enum NavOutcome { succeeded, canceled, aborted, unknown }

NavOutcome navOutcome(Object? status) => switch (status) {
  4 => NavOutcome.succeeded,
  5 => NavOutcome.canceled,
  6 => NavOutcome.aborted,
  _ => NavOutcome.unknown,
};

/// geometry_msgs/PoseWithCovarianceStamped for /initialpose (AMCL), ~0.5 m and ~15° of uncertainty.
const initialPoseTopic = '/initialpose';
String initialPoseType(RosVersion v) =>
    v == RosVersion.ros2 ? 'geometry_msgs/msg/PoseWithCovarianceStamped' : 'geometry_msgs/PoseWithCovarianceStamped';

Map<String, dynamic> initialPoseMessage(RosVersion v, String frame, double x, double y, double yaw) {
  final covariance = List<double>.filled(36, 0)..[0] = 0.25..[7] = 0.25..[35] = 0.068;
  return {
    'header': {'stamp': _stamp(v), 'frame_id': frame, if (v == RosVersion.ros1) 'seq': 0},
    'pose': {'pose': _pose(x, y, yaw), 'covariance': covariance},
  };
}
