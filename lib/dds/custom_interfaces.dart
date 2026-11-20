/// The user's own ROS 2 interface definitions (.msg / .srv / .action text) for the direct connection,
/// kept on the device and merged over the bundled Humble interfaces.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'ros_interfaces.dart';

const _key = 'ros2_custom_interfaces';

/// Saved definitions: `pkg/msg/Name` (or `pkg/srv/…`, `pkg/action/…`) → definition text.
Future<Map<String, String>> loadCustomInterfaces() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return {};
    return Map<String, String>.from(jsonDecode(raw) as Map);
  } catch (_) {
    return {};
  }
}

Future<void> saveCustomInterfaces(Map<String, String> definitions) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_key, jsonEncode(definitions));
}

/// `pkg/Name` → `pkg/msg/Name`; null when [input] is not `pkg/Name` or `pkg/(msg|srv|action)/Name`.
String? interfaceName(String input) {
  final t = input.trim();
  final m = RegExp(r'^([a-z][a-z0-9_]*)/((msg|srv|action)/)?([A-Z][A-Za-z0-9]*)$').firstMatch(t);
  if (m == null) return null;
  return '${m[1]}/${m[3] ?? 'msg'}/${m[4]}';
}

/// The interface (`pkg/srv/Name`, `pkg/action/Name`, `pkg/msg/Name`) a wire type belongs to:
/// `pkg/srv/Name_Request` → `pkg/srv/Name`, `pkg/action/Name_SendGoal_Request` → `pkg/action/Name`.
String baseInterface(String rosType) {
  final p = rosType.split('/');
  if (p.length != 3) return rosType;
  var name = p[2];
  if (p[1] == 'srv') name = name.replaceFirst(RegExp(r'_(Request|Response)$'), '');
  if (p[1] == 'action') {
    name = name.replaceFirst(RegExp(r'_(SendGoal_Request|SendGoal_Response|GetResult_Request|GetResult_Response|'
        r'FeedbackMessage|Goal|Result|Feedback)$'), '');
  }
  return '${p[0]}/${p[1]}/$name';
}

class DefinitionCheck {
  const DefinitionCheck({this.error, this.missing = const [], this.fields = 0});

  /// Why the text cannot be used at all (syntax, wrong number of `---` sections).
  final String? error;

  /// Nested message types it refers to that are not known yet (add them too).
  final List<String> missing;
  final int fields;
  bool get ok => error == null && missing.isEmpty;
}

/// Checks [text] as the definition of [type] (`pkg/kind/Name`) against what [known] already has.
DefinitionCheck checkDefinition(String type, String text, RosInterfaces known) {
  final p = type.split('/');
  if (p.length != 3) return const DefinitionCheck(error: 'Name it like my_robot_msgs/msg/Status');
  final sections = text.split(RegExp(r'^---\s*$', multiLine: true));
  final expected = switch (p[1]) { 'srv' => 2, 'action' => 3, _ => 1 };
  if (sections.length != expected) {
    return DefinitionCheck(error: expected == 1
        ? 'A message has no "---" lines'
        : 'A ${p[1] == 'srv' ? 'service' : 'action'} needs ${expected - 1} "---" line${expected > 2 ? 's' : ''} '
            '(found ${sections.length - 1})');
  }
  final missing = <String>{};
  var fields = 0;
  for (final section in sections) {
    final RosMessageSpec spec;
    try {
      spec = parseMessage(type, p[0], section);
    } on FormatException catch (e) {
      return DefinitionCheck(error: e.message);
    }
    fields += spec.fields.length;
    for (final f in spec.fields) {
      if (!f.isPrimitive && f.type != type && !known.has(f.type)) missing.add(f.type);
    }
  }
  return DefinitionCheck(missing: missing.toList()..sort(), fields: fields);
}
