import 'navigation_goal.dart' show RosVersion;
import 'robot_profile.dart';

/// Speed presets scale the profile maximum. The default is the slowest one.
enum SpeedPreset {
  slow(0.3, 'Slow'),
  normal(0.6, 'Normal'),
  fast(1.0, 'Fast');

  const SpeedPreset(this.scale, this.label);
  final double scale;
  final String label;
}

/// Stick deflections in [-1, 1], screen convention: x right, y down (as flutter_joystick reports).
class StickInput {
  final double leftX, leftY, rightX, rightY;
  const StickInput({this.leftX = 0, this.leftY = 0, this.rightX = 0, this.rightY = 0});
  static const zero = StickInput();
  bool get isZero => leftX == 0 && leftY == 0 && rightX == 0 && rightY == 0;
}

/// A velocity command in ROS conventions: x forward, y left, positive yaw / steering = turn left.
class DriveCommand {
  final double linearX, linearY, linearZ, angularZ, steering;
  const DriveCommand({this.linearX = 0, this.linearY = 0, this.linearZ = 0, this.angularZ = 0, this.steering = 0});
  static const stop = DriveCommand();
  bool get isStop => linearX == 0 && linearY == 0 && linearZ == 0 && angularZ == 0 && steering == 0;
}

/// Layout per drive type (pushing a stick up/left means forward/left):
///  - differential: left stick vertical = forward/back, right stick horizontal = turn
///  - holonomic:    left stick = translate (forward/back + sideways), right stick horizontal = rotate
///  - ackermann:    left stick vertical = speed (forward/reverse), right stick horizontal = steering angle
DriveCommand commandFor(RobotProfile profile, SpeedPreset preset, StickInput input) {
  final linear = profile.maxLinear * preset.scale;
  final angular = profile.maxAngular * preset.scale;
  double c(double v) => v.clamp(-1.0, 1.0) + 0.0; // + 0.0 turns -0.0 into 0.0
  switch (profile.drive) {
    case DriveType.differential:
      return DriveCommand(linearX: c(-input.leftY) * linear, angularZ: c(-input.rightX) * angular);
    case DriveType.holonomic:
      return DriveCommand(linearX: c(-input.leftY) * linear, linearY: c(-input.leftX) * linear,
          angularZ: c(-input.rightX) * angular);
    case DriveType.ackermann:
      // Steering is a position, not a rate, so it is not scaled by the speed preset.
      return DriveCommand(linearX: c(-input.leftY) * linear, steering: c(-input.rightX) * profile.maxSteering);
    case DriveType.none:
    case DriveType.aerial: // drones need the heading: see droneSetpoint in drone.dart
      return DriveCommand.stop;
  }
}

/// The rosbridge `msg` for [profile]'s command topic.
/// The message for [command]. [stamped]: the robot's command topic is `geometry_msgs/TwistStamped` (Nav2 and
/// ros2_control since Jazzy can be set up that way, and do by default from Kilted on). Its stamp is left at zero:
/// the phone's clock is not the robot's (nor sim time), and drivers such as ros2_control's diff_drive_controller
/// take a zero stamp as "now".
Map<String, dynamic> commandMessage(RobotProfile profile, DriveCommand command, RosVersion version,
    {bool stamped = false}) {
  final stamp = version == RosVersion.ros2 ? {'sec': 0, 'nanosec': 0} : {'secs': 0, 'nsecs': 0};
  if (profile.drive != DriveType.ackermann) {
    final twist = {
      'linear': {'x': command.linearX, 'y': command.linearY, 'z': command.linearZ},
      'angular': {'x': 0.0, 'y': 0.0, 'z': command.angularZ},
    };
    if (!stamped) return twist;
    return {
      'header': {'stamp': stamp, 'frame_id': 'base_link', if (version == RosVersion.ros1) 'seq': 0},
      'twist': twist,
    };
  }
  return {
    'header': {'stamp': stamp, 'frame_id': 'base_link', if (version == RosVersion.ros1) 'seq': 0},
    'drive': {'steering_angle': command.steering, 'steering_angle_velocity': 0.0,
      'speed': command.linearX, 'acceleration': 0.0, 'jerk': 0.0},
  };
}
