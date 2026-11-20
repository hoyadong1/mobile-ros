import 'package:material_ui/material_ui.dart';
import 'skill.dart';

/// People-facing names for the agent's skills. The manifest's descriptions are written for the model
/// ("Use it to answer questions about…"); screens where a person picks or reads steps use these instead.
class SkillLabel {
  const SkillLabel(this.title, this.description, this.icon);
  final String title;
  final String description;
  final IconData icon;
}

const _labels = <String, SkillLabel>{
  'move': SkillLabel('Drive forward or back', 'Drives a set distance. A negative distance goes backward.', Icons.straight),
  'rotate': SkillLabel('Turn in place', 'Turns by an angle. Positive turns left.', Icons.rotate_left),
  'strafe': SkillLabel('Slide sideways', 'Moves sideways. Positive goes left.', Icons.swap_horiz),
  'go_to_place': SkillLabel('Go to a saved place', 'Navigates to a place saved on the map.', Icons.place_outlined),
  'navigate_to': SkillLabel('Go to a map point', 'Navigates to x, y on the map.', Icons.near_me_outlined),
  'look': SkillLabel('Take a camera picture', 'Takes a picture with the robot\'s camera.', Icons.photo_camera_outlined),
  'get_status': SkillLabel('Report status', 'Says what the robot is doing.', Icons.info_outline),
  'cancel_navigation': SkillLabel('Cancel navigation', 'Cancels the current navigation goal.', Icons.cancel_outlined),
  'stop': SkillLabel('Stop', 'Stops all motion.', Icons.stop_circle_outlined),
  'run_routine': SkillLabel('Run a routine', 'Runs another saved routine.', Icons.playlist_play),
  'save_routine': SkillLabel('Save as routine', 'Saves the last actions as a routine.', Icons.save_outlined),
  'check_robot': SkillLabel('Check the robot', 'Battery and recent warnings or errors.', Icons.health_and_safety_outlined),
  'find_position': SkillLabel('Find its position', 'Matches the laser to the map and sets the position.', Icons.travel_explore),
  'save_place': SkillLabel('Save this spot', 'Saves where the robot is as a named place.', Icons.bookmark_add_outlined),
  'save_map': SkillLabel('Save the map', 'Saves the map being made.', Icons.save_alt),
};

/// The order skills are offered in: everyday motion first.
const _order = ['move', 'rotate', 'strafe', 'go_to_place', 'navigate_to', 'look', 'get_status', 'check_robot',
  'find_position', 'cancel_navigation', 'stop', 'run_routine', 'save_routine', 'save_place', 'save_map'];

SkillLabel skillLabel(String name) => _labels[name] ?? SkillLabel(name, '', Icons.bolt);

List<Skill> inEverydayOrder(Iterable<Skill> skills) {
  int rank(Skill s) {
    final i = _order.indexOf(s.name);
    return i < 0 ? _order.length : i;
  }
  return skills.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
}

const _paramLabels = <String, String>{
  'distance_m': 'Distance (m)',
  'angle_deg': 'Angle (°)',
  'speed': 'Speed',
  'x': 'x (m)',
  'y': 'y (m)',
  'yaw_deg': 'Final heading (°)',
  'name': 'Name',
};

String paramLabel(SkillParam p) => '${_paramLabels[p.name] ?? p.name}${p.required ? '' : ' (optional)'}';

/// One readable line for a step: "Drive forward or back · 0.5 m · slow".
String describeCall(SkillCall call) {
  final l = skillLabel(call.name);
  String value(String key, Object? raw) {
    // 360.0 reads as 360; 0.25 stays 0.25.
    final v = raw is double && raw == raw.roundToDouble() ? raw.toInt() : raw;
    return switch (key) {
    'distance_m' => '$v m',
    'angle_deg' || 'yaw_deg' => '$v°',
    'x' => 'x $v',
    'y' => 'y $v',
    _ => '$v',
    };
  }
  final parts = [for (final e in call.args.entries) if (e.value != null) value(e.key, e.value)];
  return [l.title, ...parts].join(' · ');
}

