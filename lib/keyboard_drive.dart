import 'package:flutter/services.dart';
import 'package:gamepads/gamepads.dart';

import 'drive_command.dart';

/// Driving from a keyboard or a game controller's direction pad: Android reports a Bluetooth gamepad's
/// D-pad and buttons as keys, so the same keys serve a tablet keyboard, a desktop and a controller.
///
/// Arrows or W/S: forward and back. Arrows or A/D: turn. Q/E: slide sideways (holonomic bases only,
/// as with the on-screen left stick). Space, Escape or the controller's B button: STOP.
/// Ground robots only: a drone keeps to its on-screen sticks.
StickInput keyStick(Set<LogicalKeyboardKey> pressed) {
  bool any(List<LogicalKeyboardKey> keys) => keys.any(pressed.contains);
  final forward = any(const [LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.keyW]);
  final back = any(const [LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.keyS]);
  final left = any(const [LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.keyA]);
  final right = any(const [LogicalKeyboardKey.arrowRight, LogicalKeyboardKey.keyD]);
  final slideLeft = pressed.contains(LogicalKeyboardKey.keyQ), slideRight = pressed.contains(LogicalKeyboardKey.keyE);
  double axis(bool negative, bool positive) => negative == positive ? 0 : negative ? -1 : 1;
  // Stick conventions: up is negative Y, right is positive X.
  return StickInput(leftY: axis(forward, back), leftX: axis(slideLeft, slideRight), rightX: axis(left, right));
}

/// Keys that stop the robot at once.
bool isStopKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.space || key == LogicalKeyboardKey.escape ||
    key == LogicalKeyboardKey.gameButtonB;

/// Keys this screen drives with (others go on to the rest of the app).
bool isDriveKey(LogicalKeyboardKey key) => isStopKey(key) || _driveKeys.contains(key);

final _driveKeys = {
  LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown, LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.keyW, LogicalKeyboardKey.keyA, LogicalKeyboardKey.keyS, LogicalKeyboardKey.keyD,
  LogicalKeyboardKey.keyQ, LogicalKeyboardKey.keyE,
};

/// One game controller event, as the drive screen uses it: a stick axis (-1..1, up and right positive)
/// or a button (1 pressed, 0 released).
typedef PadEvent = ({GamepadAxis? axis, GamepadButton? button, double value});

/// The controller's analog sticks as a [StickInput], the same as the on-screen sticks: left stick drives
/// (up = forward, sideways on a holonomic base), right stick turns. A small dead zone keeps a resting
/// stick that does not quite centre from creeping the robot.
StickInput padStick(Map<GamepadAxis, double> axes, {double deadZone = 0.12}) {
  double v(GamepadAxis a) {
    final x = (axes[a] ?? 0).clamp(-1.0, 1.0);
    if (x.abs() < deadZone) return 0;
    // Rescaled so motion starts from zero at the edge of the dead zone.
    return (x.abs() - deadZone) / (1 - deadZone) * x.sign;
  }
  // Pad up is +1; a stick pushed up is negative Y on the screen sticks.
  return StickInput(leftX: v(GamepadAxis.leftStickX), leftY: -v(GamepadAxis.leftStickY), rightX: v(GamepadAxis.rightStickX));
}

/// Every controller's events, simplified; empty where the platform has none (tests, unsupported).
Stream<PadEvent> gamepadEvents() => Gamepads.normalizedEvents.map((e) => (axis: e.axis, button: e.button, value: e.value));
