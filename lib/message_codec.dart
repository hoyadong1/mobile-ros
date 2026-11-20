import 'dart:convert';

void validateMessageFields(Map<String, dynamic> fields) {
  for (final entry in fields.entries) {
    if (entry.key.isEmpty || entry.key.contains('/')) {
      throw const FormatException('Field names must be nonempty and cannot contain /');
    }
    final value = entry.value;
    if (value is Map<String, dynamic>) {
      validateMessageFields(value);
    } else if (value is! String || value.trim().isEmpty) {
      throw FormatException('Invalid type for ${entry.key}');
    }
  }
}

/// Convert form input to actual ROS JSON, preserving nested objects and types.
Map<String, dynamic> buildRosMessage(Map<String, dynamic> fields,
    Map<String, String> input, Map<String, dynamic> types,
    [String prefix = '', Set<String> ancestors = const {}]) {
  return fields.map((key, schema) {
    final path = prefix.isEmpty ? key : '$prefix/$key';
    if (schema is Map<String, dynamic>) {
      return MapEntry(key, buildRosMessage(schema, input, types, path, ancestors));
    }
    if (schema is! String) throw FormatException('Invalid schema: $path');
    if (types.containsKey(schema)) {
      if (ancestors.contains(schema)) throw FormatException('Recursive type: $schema');
      return MapEntry(key, buildRosMessage(
        Map<String, dynamic>.from(types[schema]['fields'] as Map),
        input, types, path, {...ancestors, schema}));
    }
    return MapEntry(key, parseRosValue(schema, input[path] ?? '', path, types));
  });
}

dynamic parseRosValue(String type, String input, String path,
    Map<String, dynamic> types) {
  final text = input.trim();
  if (type == 'string') return input;
  if (type == 'bool' || type == 'boolean') {
    if (text == 'true') return true;
    if (text == 'false') return false;
    throw FormatException('$path: enter true or false');
  }
  if (['double', 'float', 'float32', 'float64'].contains(type)) {
    final value = double.tryParse(text);
    if (value == null || !value.isFinite) throw FormatException('$path: invalid number');
    return value;
  }
  final integer = RegExp(r'^(u?int)(8|16|32|64)?$').firstMatch(type);
  if (integer != null) {
    final value = int.tryParse(text);
    final bits = int.parse(integer.group(2) ?? '32');
    final unsigned = integer.group(1) == 'uint';
    final parsed = BigInt.tryParse(text);
    final min = unsigned ? BigInt.zero : -(BigInt.one << (bits - 1));
    final max = (BigInt.one << (unsigned ? bits : bits - 1)) - BigInt.one;
    if (value == null || parsed == null || parsed < min || parsed > max) {
      throw FormatException('$path: invalid $type');
    }
    return value;
  }
  if (type.startsWith('array<') && type.endsWith('>')) {
    final value = jsonDecode(text);
    if (value is! List) throw FormatException('$path: enter a JSON array');
    final elementType = type.substring(6, type.length - 1);
    return value.asMap().entries.map((entry) {
      if (elementType == 'string' && entry.value is! String) {
        throw FormatException('$path: expected strings');
      }
      return parseRosValue(elementType,
        entry.value is String ? entry.value as String : jsonEncode(entry.value),
        '$path[${entry.key}]', types);
    }).toList();
  }
  if (types.containsKey(type)) {
    final value = jsonDecode(text);
    if (value is! Map<String, dynamic>) throw FormatException('$path: expected object');
    final flattened = <String, String>{};
    void flatten(Map<String, dynamic> object, String prefix) {
      object.forEach((key, value) {
        final name = prefix.isEmpty ? key : '$prefix/$key';
        if (value is Map<String, dynamic>) { flatten(value, name); }
        else { flattened[name] = value is String ? value : jsonEncode(value); }
      });
    }
    flatten(value, '');
    return buildRosMessage(Map<String, dynamic>.from(types[type]['fields'] as Map), flattened, types);
  }
  throw FormatException('$path: unsupported type $type');
}
