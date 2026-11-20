import 'package:material_ui/material_ui.dart';
import 'skill.dart';
import '../app_language.dart';
import '../l10n/generated/app_localizations.dart';

/// People-facing names for the agent's skills. The manifest's descriptions are written for the model
/// ("Use it to answer questions about…"); screens where a person picks or reads steps use these instead.
class SkillLabel {
  const SkillLabel(this.title, this.description, this.icon);
  final String title;
  final String description;
  final IconData icon;
}

const _icons = <String, IconData>{
  'move': Icons.straight, 'rotate': Icons.rotate_left, 'strafe': Icons.swap_horiz,
  'go_to_place': Icons.place_outlined, 'navigate_to': Icons.near_me_outlined, 'look': Icons.photo_camera_outlined,
  'get_status': Icons.info_outline, 'cancel_navigation': Icons.cancel_outlined, 'stop': Icons.stop_circle_outlined,
  'run_routine': Icons.playlist_play, 'save_routine': Icons.save_outlined,
  'check_robot': Icons.health_and_safety_outlined, 'find_position': Icons.travel_explore,
  'save_place': Icons.bookmark_add_outlined, 'save_map': Icons.save_alt,
};

/// The order skills are offered in: everyday motion first.
const _order = ['move', 'rotate', 'strafe', 'go_to_place', 'navigate_to', 'look', 'get_status', 'check_robot',
  'find_position', 'cancel_navigation', 'stop', 'run_routine', 'save_routine', 'save_place', 'save_map'];

/// [name]'s label in the app's language ([strings], or the chosen language); a skill without one (a
/// learned tool) shows its own name.
SkillLabel skillLabel(String name, [AppLocalizations? strings]) {
  final s = strings ?? appStrings;
  final (title, description) = switch (name) {
    'move' => (s.skillMove, s.skillMoveDesc),
    'rotate' => (s.skillRotate, s.skillRotateDesc),
    'strafe' => (s.skillStrafe, s.skillStrafeDesc),
    'go_to_place' => (s.skillGoToPlace, s.skillGoToPlaceDesc),
    'navigate_to' => (s.skillNavigateTo, s.skillNavigateToDesc),
    'look' => (s.skillLook, s.skillLookDesc),
    'get_status' => (s.skillGetStatus, s.skillGetStatusDesc),
    'cancel_navigation' => (s.skillCancelNavigation, s.skillCancelNavigationDesc),
    'stop' => (s.skillStop, s.skillStopDesc),
    'run_routine' => (s.skillRunRoutine, s.skillRunRoutineDesc),
    'save_routine' => (s.skillSaveRoutine, s.skillSaveRoutineDesc),
    'check_robot' => (s.skillCheckRobot, s.skillCheckRobotDesc),
    'find_position' => (s.skillFindPosition, s.skillFindPositionDesc),
    'save_place' => (s.skillSavePlace, s.skillSavePlaceDesc),
    'save_map' => (s.skillSaveMap, s.skillSaveMapDesc),
    _ => (name, ''),
  };
  return SkillLabel(title, description, _icons[name] ?? Icons.bolt);
}

List<Skill> inEverydayOrder(Iterable<Skill> skills) {
  int rank(Skill s) {
    final i = _order.indexOf(s.name);
    return i < 0 ? _order.length : i;
  }
  return skills.toList()..sort((a, b) => rank(a).compareTo(rank(b)));
}

String paramLabel(SkillParam p, [AppLocalizations? strings]) {
  final s = strings ?? appStrings;
  final label = switch (p.name) {
    'distance_m' => s.paramDistance,
    'angle_deg' => s.paramAngle,
    'speed' => s.paramSpeed,
    'x' => 'x (m)',
    'y' => 'y (m)',
    'yaw_deg' => s.paramFinalHeading,
    'name' => s.name,
    _ => p.name,
  };
  return p.required ? label : s.paramOptional(label);
}

/// A choice's words: the speed names in the app's language, anything else as it is.
String valueLabel(String value, [AppLocalizations? strings]) {
  final s = strings ?? appStrings;
  return switch (value) { 'slow' => s.slow, 'normal' => s.normal, 'fast' => s.fast, _ => value };
}

/// One readable line for a step: "Drive forward or back · 0.5 m · slow".
String describeCall(SkillCall call, [AppLocalizations? strings]) {
  final l = skillLabel(call.name, strings);
  String value(String key, Object? raw) {
    // 360.0 reads as 360; 0.25 stays 0.25.
    final v = raw is double && raw == raw.roundToDouble() ? raw.toInt() : raw;
    return switch (key) {
    'distance_m' => '$v m',
    'angle_deg' || 'yaw_deg' => '$v°',
    'x' => 'x $v',
    'y' => 'y $v',
    'speed' => valueLabel('$v', strings),
    _ => '$v',
    };
  }
  final parts = [for (final e in call.args.entries) if (e.value != null) value(e.key, e.value)];
  return [l.title, ...parts].join(' · ');
}

