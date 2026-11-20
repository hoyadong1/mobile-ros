/// ROS 2 interface definitions (.msg / .srv / .action text) for the direct DDS connection. Without
/// rosbridge's rosapi the phone has to know message layouts itself: the standard Humble interfaces are
/// bundled (assets/ros2_interfaces.json) and users can add their own .msg text.
library;

const primitiveTypes = {
  'bool', 'byte', 'char', 'float32', 'float64', 'int8', 'uint8', 'int16', 'uint16',
  'int32', 'uint32', 'int64', 'uint64', 'string', 'wstring',
};

class RosField {
  const RosField(this.name, this.type, {this.arrayLen = -1, this.defaultValue});
  final String name;

  /// A primitive from [primitiveTypes] or a full message type `pkg/msg/Name`.
  final String type;

  /// -1: not an array, 0: unbounded (or bounded `<=N`) sequence, N: fixed array of N.
  final int arrayLen;
  final String? defaultValue;
  bool get isPrimitive => primitiveTypes.contains(type);
}

class RosMessageSpec {
  const RosMessageSpec(this.type, this.fields, {this.constants = const []});
  final String type;
  final List<RosField> fields;

  /// (type, name, value) of each constant, in file order.
  final List<(String, String, String)> constants;
}

/// `pkg/Name` → `pkg/msg/Name`; full names pass through.
String canonicalType(String type) {
  final parts = type.split('/');
  return parts.length == 2 ? '${parts[0]}/msg/${parts[1]}' : type;
}

/// `nav_msgs/msg/Odometry` → `nav_msgs::msg::dds_::Odometry_` (the name ROS 2 RMWs use on the wire).
String ddsTypeName(String type) {
  final parts = canonicalType(type).split('/');
  if (parts.length != 3) throw FormatException('Not a ROS 2 type name: $type');
  return '${parts[0]}::${parts[1]}::dds_::${parts[2]}_';
}

/// Inverse of [ddsTypeName]; null for names that are not ROS types.
String? rosTypeFromDds(String name) {
  final m = RegExp(r'^(\w+)::(\w+)::dds_::(\w+)_$').firstMatch(name);
  return m == null ? null : '${m[1]}/${m[2]}/${m[3]}';
}

class RosInterfaces {
  RosInterfaces(Map<String, String> sources) : _sources = Map.of(sources);

  /// Keys are `pkg/msg/Name`, `pkg/srv/Name` or `pkg/action/Name`; values the definition text.
  final Map<String, String> _sources;
  final _cache = <String, RosMessageSpec?>{};

  /// Adds or replaces a definition (e.g. a robot's custom message pasted by the user).
  void add(String type, String text) {
    _sources[canonicalType(type)] = text;
    _cache.clear();
  }

  bool has(String type) => spec(type) != null;

  /// Message types (`pkg/msg/Name`) available, sorted.
  List<String> get messageTypes => [for (final k in _sources.keys) if (k.contains('/msg/')) k]..sort();

  /// Service and action names, to answer "what type is X" questions.
  Iterable<String> get allInterfaces => _sources.keys;

  /// The layout of a message type. Besides `pkg/msg/Name` this understands the parts of services
  /// (`pkg/srv/Name_Request`, `_Response`) and actions (`pkg/action/Name_Goal`, `_Result`, `_Feedback`,
  /// `_SendGoal_Request`/`_Response`, `_GetResult_Request`/`_Response`, `_FeedbackMessage`).
  RosMessageSpec? spec(String type) {
    final key = canonicalType(type);
    if (_cache.containsKey(key)) return _cache[key];
    RosMessageSpec? result;
    try {
      result = _build(key);
    } on FormatException {
      result = null;
    }
    return _cache[key] = result;
  }

  RosMessageSpec? _build(String key) {
    final parts = key.split('/');
    if (parts.length != 3) return null;
    final pkg = parts[0], kind = parts[1], name = parts[2];
    if (kind == 'msg') {
      final text = _sources[key];
      return text == null ? null : parseMessage(key, pkg, text);
    }
    if (kind == 'srv') {
      for (final (suffix, index) in [('_Request', 0), ('_Response', 1)]) {
        if (!name.endsWith(suffix)) continue;
        final text = _sources['$pkg/srv/${name.substring(0, name.length - suffix.length)}'];
        if (text == null) return null;
        return parseMessage(key, pkg, _section(text, index));
      }
      return null;
    }
    if (kind == 'action') {
      const uuid = RosField('goal_id', 'unique_identifier_msgs/msg/UUID');
      final derived = <String, List<RosField> Function(String base)>{
        '_SendGoal_Request': (b) => [uuid, RosField('goal', '$pkg/action/${b}_Goal')],
        '_SendGoal_Response': (_) => const [RosField('accepted', 'bool'), RosField('stamp', 'builtin_interfaces/msg/Time')],
        '_GetResult_Request': (_) => const [uuid],
        '_GetResult_Response': (b) => [const RosField('status', 'int8'), RosField('result', '$pkg/action/${b}_Result')],
        '_FeedbackMessage': (b) => [uuid, RosField('feedback', '$pkg/action/${b}_Feedback')],
      };
      for (final entry in derived.entries) {
        if (!name.endsWith(entry.key)) continue;
        final base = name.substring(0, name.length - entry.key.length);
        if (!_sources.containsKey('$pkg/action/$base')) return null;
        return RosMessageSpec(key, entry.value(base));
      }
      for (final (suffix, index) in [('_Goal', 0), ('_Result', 1), ('_Feedback', 2)]) {
        if (!name.endsWith(suffix)) continue;
        final text = _sources['$pkg/action/${name.substring(0, name.length - suffix.length)}'];
        if (text == null) return null;
        return parseMessage(key, pkg, _section(text, index));
      }
    }
    return null;
  }

  static String _section(String text, int index) {
    final sections = text.split(RegExp(r'^---\s*$', multiLine: true));
    return index < sections.length ? sections[index] : '';
  }
}

/// Parses one message definition. Nested types without a package belong to [pkg].
RosMessageSpec parseMessage(String type, String pkg, String text) {
  final fields = <RosField>[];
  final constants = <(String, String, String)>[];
  for (var line in text.split('\n')) {
    line = _stripComment(line).trim();
    if (line.isEmpty) continue;
    final m = RegExp(r'^(\S+)\s+([A-Za-z]\w*)\s*(=\s*(.*)|\s+(.*))?$').firstMatch(line);
    if (m == null) throw FormatException('Cannot read "$line" in $type');
    final (base, arrayLen) = _parseType(m[1]!, pkg);
    if (m[4] != null) {
      constants.add((base, m[2]!, m[4]!.trim()));
    } else {
      fields.add(RosField(m[2]!, base, arrayLen: arrayLen, defaultValue: m[5]?.trim()));
    }
  }
  return RosMessageSpec(type, fields, constants: constants);
}

String _stripComment(String line) {
  String? quote;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"' || c == "'") {
      quote = quote == null ? c : (quote == c ? null : quote);
    } else if (c == '#' && quote == null) {
      return line.substring(0, i);
    }
  }
  return line;
}

(String, int) _parseType(String token, String pkg) {
  final m = RegExp(r'^([^\[\]]+)(\[(<=)?(\d*)\])?$').firstMatch(token);
  if (m == null) throw FormatException('Unknown type $token');
  var base = m[1]!;
  final arrayLen = m[2] == null ? -1 : (m[3] != null || m[4]!.isEmpty ? 0 : int.parse(m[4]!));
  base = base.replaceFirst(RegExp(r'<=\d+$'), ''); // bounded strings serialize like strings
  if (!primitiveTypes.contains(base)) {
    // Message names are CamelCase, optionally with a package: Status, pkg/Status, pkg/msg/Status.
    if (!RegExp(r'^([a-z][a-z0-9_]*/(msg/)?)?[A-Z][A-Za-z0-9]*$').hasMatch(base)) {
      throw FormatException('Unknown type "$base"');
    }
    if (base == 'Header') {
      base = 'std_msgs/msg/Header';
    } else if (base.contains('/')) {
      base = canonicalType(base);
    } else {
      base = '$pkg/msg/$base';
    }
  }
  return (base, arrayLen);
}

/// rosapi-style `typedefs` for [type] and every type nested in it (rosapi spells types `pkg/Name`).
List<Map<String, dynamic>> rosapiTypedefs(
  RosInterfaces interfaces,
  String type,
) {
  String short(String t) {
    final p = t.split('/');
    return p.length == 3 ? '${p[0]}/${p[2]}' : t;
  }

  String example(RosField f) {
    if (f.arrayLen >= 0) return '[]';
    if (!f.isPrimitive) return '{}';
    if (f.defaultValue != null) return f.defaultValue!;
    return switch (f.type) {
      'bool' => 'False',
      'float32' || 'float64' => '0.0',
      'string' || 'wstring' => '',
      _ => '0',
    };
  }

  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  final queue = [canonicalType(type)];
  while (queue.isNotEmpty) {
    final t = queue.removeAt(0);
    if (!seen.add(t)) continue;
    final spec = interfaces.spec(t);
    if (spec == null) {
      if (out.isEmpty) throw StateError('No message definition for $type');
      continue;
    }
    out.add({
      'type': short(t),
      'fieldnames': [for (final f in spec.fields) f.name],
      'fieldtypes': [
        for (final f in spec.fields) f.isPrimitive ? f.type : short(f.type),
      ],
      'fieldarraylen': [for (final f in spec.fields) f.arrayLen],
      'examples': [for (final f in spec.fields) example(f)],
      'constnames': [for (final c in spec.constants) c.$2],
      'constvalues': [for (final c in spec.constants) c.$3],
    });
    for (final f in spec.fields) {
      if (!f.isPrimitive) queue.add(f.type);
    }
  }
  return out;
}
