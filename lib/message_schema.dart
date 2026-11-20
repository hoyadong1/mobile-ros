import 'dart:convert';

/// `pkg/msg/Type` and `pkg/Type` name the same message; rosapi reports the short form.
String normalizeType(String t) => t.replaceFirst('/msg/', '/');

class FieldDef {
  const FieldDef(this.name, this.type, {this.arrayLen = -1, this.example = ''});
  final String name;
  final String type;

  /// -1: not an array, 0: unbounded array, n: fixed length n.
  final int arrayLen;
  final String example;
  bool get isArray => arrayLen >= 0;
}

class TypeDef {
  const TypeDef(this.type, this.fields, {this.constants = const {}});
  final String type;
  final List<FieldDef> fields;

  /// Message constants (e.g. POWER_SUPPLY_STATUS_CHARGING: 1), offered as quick picks.
  final Map<String, String> constants;
}

// Not const: the 64-bit limits are parsed at run time because JavaScript (the web build) cannot
// hold them as exact literals; there they round to the nearest double, which is fine for range checks.
final _intRanges = <String, (int, int)>{
  'int8': (-128, 127),
  'uint8': (0, 255),
  'byte': (0, 255),
  'char': (0, 255),
  'octet': (0, 255),
  'int16': (-32768, 32767),
  'uint16': (0, 65535),
  'int32': (-2147483648, 2147483647),
  'uint32': (0, 4294967295),
  'int': (-2147483648, 2147483647),
  'int64': (int.parse('-9223372036854775808'), int.parse('9223372036854775807')),
  'uint64': (0, int.parse('9223372036854775807')),
};
const _floats = {'float', 'double', 'float32', 'float64'};
const _bools = {'bool', 'boolean'};
const _strings = {'string', 'wstring'};

bool isIntType(String t) => _intRanges.containsKey(t);
bool isFloatType(String t) => _floats.contains(t);
bool isBoolType(String t) => _bools.contains(t);
bool isStringType(String t) =>
    _strings.contains(t) || t.startsWith('string<') || t.startsWith('wstring<');

/// Message structure for one root type, from rosapi's message_details (or the bundled offline list).
class MessageSchema {
  MessageSchema(this.root, Map<String, TypeDef> types)
    : types = {..._builtins, ...types};
  final String root;
  final Map<String, TypeDef> types;

  // ROS 1 rosapi reports time/duration as primitives; they are {secs, nsecs} on the wire.
  static const _builtins = {
    'time': TypeDef('time', [
      FieldDef('secs', 'int32', example: '0'),
      FieldDef('nsecs', 'int32', example: '0'),
    ]),
    'duration': TypeDef('duration', [
      FieldDef('secs', 'int32', example: '0'),
      FieldDef('nsecs', 'int32', example: '0'),
    ]),
  };

  /// From a /rosapi/message_details answer: {typedefs: [{type, fieldnames, fieldtypes, fieldarraylen,
  /// examples, constnames, constvalues}, ...]}, the first typedef being the requested type.
  factory MessageSchema.fromRosapi(Map response) {
    final defs = response['typedefs'];
    if (defs is! List || defs.isEmpty) {
      throw const FormatException('The robot did not describe this type.');
    }
    final types = <String, TypeDef>{};
    for (final d in defs.cast<Map>()) {
      final names = List<String>.from(d['fieldnames'] as List);
      final kinds = List<String>.from(d['fieldtypes'] as List);
      final lens =
          (d['fieldarraylen'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          List.filled(names.length, -1);
      final examples =
          (d['examples'] as List?)?.map((e) => '$e').toList() ??
          List.filled(names.length, '');
      final constants = <String, String>{};
      final cn = (d['constnames'] as List?) ?? const [],
          cv = (d['constvalues'] as List?) ?? const [];
      for (var i = 0; i < cn.length && i < cv.length; i++) {
        final n = '${cn[i]}';
        // ROS 2 rosapi also lists field defaults (lowercase), SLOT_TYPES and X__DEFAULT here.
        if (RegExp(r'^[A-Z][A-Z0-9_]*$').hasMatch(n) &&
            n != 'SLOT_TYPES' &&
            !n.endsWith('__DEFAULT')) {
          constants[n] = '${cv[i]}';
        }
      }
      final type = normalizeType('${d['type']}');
      types[type] = TypeDef(type, [
        for (var i = 0; i < names.length; i++)
          FieldDef(
            names[i],
            normalizeType(kinds[i]),
            arrayLen: i < lens.length ? lens[i] : -1,
            example: i < examples.length ? examples[i] : '',
          ),
      ], constants: constants);
    }
    return MessageSchema(normalizeType('${defs.first['type']}'), types);
  }

  /// From the bundled offline definitions (assets/message_types.json): {type: {fields: {name: type|{...}}}},
  /// where nested maps are anonymous sub-messages and `array<T>` marks arrays.
  factory MessageSchema.fromLegacy(String root, Map legacy) {
    final types = <String, TypeDef>{};
    TypeDef convert(String name, Map fields) {
      final list = <FieldDef>[];
      fields.forEach((key, value) {
        if (value is Map) {
          final sub = '$name/$key';
          types[sub] = convert(sub, value);
          list.add(FieldDef('$key', sub));
        } else {
          var t = '$value';
          var len = -1;
          if (t.startsWith('array<') && t.endsWith('>')) {
            t = t.substring(6, t.length - 1);
            len = 0;
          }
          list.add(FieldDef('$key', normalizeType(t), arrayLen: len));
        }
      });
      return TypeDef(name, list);
    }

    legacy.forEach((name, def) {
      if (def is Map && def['fields'] is Map) {
        types[normalizeType('$name')] = convert(
          normalizeType('$name'),
          def['fields'] as Map,
        );
      }
    });
    if (!types.containsKey(normalizeType(root))) {
      throw FormatException('Unknown type $root');
    }
    return MessageSchema(normalizeType(root), types);
  }

  TypeDef? def(String type) => types[normalizeType(type)];
  bool isMessage(String type) => def(type) != null;

  /// Numeric scalar leaf fields available for a generic sensor value display.
  List<String> numericFieldPaths([String? type]) {
    final result = <String>[];
    void visit(String current, String prefix, Set<String> parents) {
      if (parents.contains(current)) return;
      final definition = def(current);
      if (definition == null) return;
      for (final field in definition.fields) {
        final path = _join(prefix, field.name);
        if (!field.isArray && isMessage(field.type)) {
          visit(field.type, path, {...parents, current});
        } else if (!field.isArray && (isIntType(field.type) || isFloatType(field.type))) {
          result.add(path);
        }
      }
    }
    visit(type ?? root, '', {});
    return result;
  }

  /// A complete message with every field at its default (rosapi examples, else zero / empty).
  Map<String, dynamic> defaults([String? type]) => {
    for (final f in def(type ?? root)!.fields) f.name: defaultField(f),
  };

  dynamic defaultField(FieldDef f) {
    if (f.isArray) {
      if (f.arrayLen == 0) return [];
      return List.generate(
        f.arrayLen,
        (_) => isMessage(f.type)
            ? defaults(f.type)
            : _defaultPrimitive(f.type, ''),
      );
    }
    return isMessage(f.type)
        ? defaults(f.type)
        : _defaultPrimitive(f.type, f.example);
  }

  dynamic _defaultPrimitive(String type, String example) {
    try {
      if (example.isNotEmpty) return parsePrimitive(type, example, '');
    } catch (_) {}
    if (isBoolType(type)) return false;
    if (isIntType(type)) return 0;
    if (isFloatType(type)) return 0.0;
    return '';
  }

  /// Validates and converts [json] (parsed JSON) to a message of [type]: numbers typed, missing fields
  /// defaulted, unknown fields rejected.
  Map<String, dynamic> coerce(Object? json, [String? type, String path = '']) {
    final d = def(type ?? root)!;
    if (json is! Map) {
      throw FormatException(
        '${path.isEmpty ? 'Message' : path}: expected an object',
      );
    }
    final known = {for (final f in d.fields) f.name};
    for (final k in json.keys) {
      if (!known.contains(k)) {
        throw FormatException(
          '${_join(path, '$k')}: no such field in ${d.type}',
        );
      }
    }
    return {
      for (final f in d.fields)
        f.name: json.containsKey(f.name)
            ? coerceField(f, json[f.name], _join(path, f.name))
            : defaultField(f),
    };
  }

  /// Converts one field's JSON value (arrays included) to its typed form.
  dynamic coerceField(FieldDef f, Object? v, String path) {
    if (f.isArray) {
      // ROS 2 rosbridge may send uint8[] as a base64 string; pass it through unchanged.
      if (v is String &&
          (f.type == 'uint8' || f.type == 'byte' || f.type == 'octet')) {
        return v;
      }
      if (v is! List) throw FormatException('$path: expected a list');
      if (f.arrayLen > 0 && v.length != f.arrayLen) {
        throw FormatException('$path: needs exactly ${f.arrayLen} items');
      }
      return [
        for (var i = 0; i < v.length; i++)
          _coerceOne(f.type, v[i], '$path[$i]'),
      ];
    }
    return _coerceOne(f.type, v, path);
  }

  dynamic _coerceOne(String type, Object? v, String path) {
    if (v == null) {
      throw FormatException(
        '${path.isEmpty ? 'Value' : path}: null is not a ROS value',
      );
    }
    if (isMessage(type)) return coerce(v, type, path);
    return parsePrimitive(type, v is String ? v : jsonEncode(v), path, raw: v);
  }

  static String _join(String a, String b) => a.isEmpty ? b : '$a/$b';
}

/// Parses form text (or a JSON value via [raw]) into a typed ROS primitive.
dynamic parsePrimitive(String type, String text, String path, {Object? raw}) {
  final where = path.isEmpty ? '' : '$path: ';
  if (isStringType(type)) {
    if (raw != null && raw is! String) {
      throw FormatException('${where}expected text');
    }
    return raw is String ? raw : text;
  }
  final t = text.trim();
  if (isBoolType(type)) {
    if (raw is bool) return raw;
    final l = t.toLowerCase();
    if (l == 'true' || l == '1') return true;
    if (l == 'false' || l == '0') return false;
    throw FormatException('${where}true or false');
  }
  if (isFloatType(type)) {
    final v = raw is num ? raw.toDouble() : double.tryParse(t);
    if (v == null || !v.isFinite) {
      throw FormatException('${where}enter a number');
    }
    return v;
  }
  final range = _intRanges[type];
  if (range != null) {
    final big = raw is num && raw.isFinite && raw == raw.truncateToDouble()
        ? BigInt.from(raw.toInt())
        : BigInt.tryParse(t);
    if (big == null) throw FormatException('${where}enter a whole number');
    if (big < BigInt.from(range.$1) || big > BigInt.from(range.$2)) {
      throw FormatException('$where$type must be ${range.$1}…${range.$2}');
    }
    return big.toInt();
  }
  throw FormatException('${where}unsupported type $type');
}

/// Text shown in a form field for a primitive value.
String formatPrimitive(Object? v) => v is String
    ? v
    : v is double && v == v.roundToDouble() && v.abs() < 1e15
    ? v.toStringAsFixed(1)
    : '$v';

/// True if [echo] (as rosbridge relays it) carries the same values as [sent]. Numbers compare with a small
/// tolerance (float32 rounding); byte arrays that come back base64-encoded are not compared.
bool sameMessage(Object? sent, Object? echo) {
  if (sent is Map && echo is Map) {
    for (final k in sent.keys) {
      if (!echo.containsKey(k) || !sameMessage(sent[k], echo[k])) return false;
    }
    return true;
  }
  if (sent is List && echo is String) return true;
  if (sent is List && echo is List) {
    if (sent.length != echo.length) return false;
    for (var i = 0; i < sent.length; i++) {
      if (!sameMessage(sent[i], echo[i])) return false;
    }
    return true;
  }
  if (sent is num && echo is num) {
    return (sent - echo).abs() <= 1e-4 * (1 + sent.abs());
  }
  if (sent is bool && echo is num) return (sent ? 1 : 0) == echo;
  return sent == echo;
}
