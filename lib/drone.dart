import 'dart:math' as math;
import 'drive_command.dart';
import 'robot_profile.dart';

/// PX4 flight mode names as MAVROS reports and accepts them (custom_mode strings).
class FlightMode {
  static const offboard = 'OFFBOARD';
  static const takeoff = 'AUTO.TAKEOFF';
  static const land = 'AUTO.LAND';
  static const hold = 'AUTO.LOITER';
  static const returnHome = 'AUTO.RTL';
}

/// `/mavros/setpoint_velocity/cmd_vel_unstamped` → `/mavros`.
String mavrosNamespace(String commandTopic) {
  final i = commandTopic.indexOf('/setpoint');
  return i > 0 ? commandTopic.substring(0, i) : '/mavros';
}

class DroneTelemetry {
  final bool connected, armed;
  final String mode;
  final double? altitude; // m above home (MAVROS global_position/rel_alt)
  final double? yaw; // rad, ENU
  final double? battery; // 0..1
  const DroneTelemetry({this.connected = false, this.armed = false, this.mode = '', this.altitude, this.yaw,
    this.battery});

  DroneTelemetry copyWith({bool? connected, bool? armed, String? mode, double? altitude, double? yaw, double? battery}) =>
      DroneTelemetry(connected: connected ?? this.connected, armed: armed ?? this.armed, mode: mode ?? this.mode,
        altitude: altitude ?? this.altitude, yaw: yaw ?? this.yaw, battery: battery ?? this.battery);

  bool get flying => armed && (altitude ?? 0) > 0.3;
  bool get offboard => mode == FlightMode.offboard;
}

/// Yaw (ENU) from a quaternion map.
double yawOf(Map q) {
  final x = (q['x'] as num).toDouble(), y = (q['y'] as num).toDouble();
  final z = (q['z'] as num).toDouble(), w = (q['w'] as num).toDouble();
  return math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
}

/// RC "mode 2" sticks → a world-frame (ENU) velocity setpoint for MAVROS:
///  left stick: up/down = climb/descend, left/right = yaw; right stick: forward/back and sideways,
///  relative to the drone's nose (rotated by [yaw] into the world frame).
DriveCommand droneSetpoint(RobotProfile profile, SpeedPreset preset, StickInput input, double yaw) {
  double c(double v) => v.clamp(-1.0, 1.0) + 0.0;
  final horizontal = profile.maxLinear * preset.scale;
  final vertical = profile.maxLinear * 0.5 * preset.scale;
  final yawRate = profile.maxAngular * preset.scale;
  final forward = c(-input.rightY) * horizontal;
  final left = c(-input.rightX) * horizontal;
  return DriveCommand(
    linearX: forward * math.cos(yaw) - left * math.sin(yaw) + 0.0,
    linearY: forward * math.sin(yaw) + left * math.cos(yaw) + 0.0,
    linearZ: c(-input.leftY) * vertical,
    angularZ: c(-input.leftX) * yawRate,
  );
}

Map<String, dynamic> setModeArgs(String mode) => {'base_mode': 0, 'custom_mode': mode};
Map<String, dynamic> armingArgs(bool arm) => {'value': arm};
