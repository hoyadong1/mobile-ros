/// What happens when the app's link to the robot drops while it is driving.
///
/// The app drives by streaming velocity commands. If the link drops it cannot send "stop", and a base
/// without a command timeout keeps executing the last command (measured on a simulated TurtleBot3:
/// 0.45 m in 3 s and still going). Stopping on a lost link is the robot's job; the app can only tell
/// the user whether something on the robot does it, and warn loudly when the link is lost mid-motion.
library;

/// Something found on the robot that stops the base when commands stop arriving, or null when nothing
/// recognisable was found (the base may still have a timeout of its own that discovery cannot see).
String? stopOnLinkLossGuard({required List<String> nodes, required List<String> topics}) {
  bool node(String name) => nodes.any((n) => n == '/$name' || n.endsWith('/$name'));
  if (node('cmd_vel_watchdog')) return 'cmd_vel watchdog';
  if (node('twist_mux')) return 'twist_mux';
  // ros2_control drive controllers stop after cmd_vel_timeout (0.5 s by default).
  final controller = RegExp(r'_(controller|cont)/cmd_vel(_unstamped)?$');
  if (node('controller_manager') && topics.any(controller.hasMatch)) return 'ros2_control drive controller';
  return null;
}

/// Shown once per robot when no [stopOnLinkLossGuard] was found.
const linkLossNotice =
    'If this app loses its connection while driving, the robot may keep its last speed until something '
    'on the robot stops it. Make sure the base stops when commands stop arriving: a command timeout in its '
    'driver, twist_mux, or robot_side/cmd_vel_watchdog.py from this app.';

/// Shown when the link drops while the robot was being driven.
const linkLostWhileMoving =
    'Connection lost while the robot was moving. It may keep moving on its last command. '
    'Stop it at the robot (emergency stop) if it does not stop by itself.';

/// Whether a link lost at [now] counts as lost mid-motion: the base was moving at that moment or had been
/// commanded to move within [window] (a stop sent just before may not have arrived).
bool lostWhileMoving({required DateTime? lastMotion, required bool movingNow, required DateTime now,
    Duration window = const Duration(seconds: 2)}) =>
    movingNow || (lastMotion != null && now.difference(lastMotion) <= window);
