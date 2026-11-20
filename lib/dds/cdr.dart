/// CDR (de)serialization of ROS 2 messages, producing the same JSON-like maps rosbridge sends so the rest
/// of the app does not care which connection it is on. Differences on purpose: byte arrays (uint8[],
/// byte[], char[]) come out as [Uint8List] rather than base64 text (the app accepts both), and
/// non-finite floats come out as null, as rosbridge's JSON does.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'ros_interfaces.dart';

class CdrCodec {
  CdrCodec(this.interfaces);
  final RosInterfaces interfaces;

  RosMessageSpec _spec(String type) =>
      interfaces.spec(type) ?? (throw FormatException('No definition for message type $type'));

  /// Decodes one sample (including its 4-byte encapsulation header).
  Map<String, dynamic> decode(String type, Uint8List sample) {
    if (sample.length < 4) throw const FormatException('Sample too short');
    final kind = sample[1];
    // 0/1: CDR (XCDR1) big/little endian. 6/7: plain XCDR2. Others (parameter lists, delimited) are not
    // used by ROS 2 message types.
    if (sample[0] != 0 || !{0, 1, 6, 7}.contains(kind)) {
      throw FormatException('Unsupported CDR encapsulation ${sample[0]}/${sample[1]}');
    }
    final r = _Reader(sample, kind.isOdd ? Endian.little : Endian.big, kind >= 6 ? 4 : 8);
    return r.message(this, _spec(type));
  }

  /// Encodes [msg] (missing fields take their defaults) as little-endian XCDR1 with header.
  Uint8List encode(String type, Map msg) {
    final w = _Writer();
    w.message(this, _spec(type), msg);
    return w.take();
  }

  /// A message with every field at its default, as rosbridge would describe an empty message.
  Map<String, dynamic> defaults(String type) => decode(type, encode(type, const {}));
}

class _Reader {
  _Reader(this.bytes, this.endian, this.maxAlign) : data = ByteData.sublistView(bytes);
  final Uint8List bytes;
  final ByteData data;
  final Endian endian;
  final int maxAlign;
  int pos = 4;

  void align(int n) {
    if (n > maxAlign) n = maxAlign;
    final rel = (pos - 4) % n;
    if (rel != 0) pos += n - rel;
  }

  void need(int n) {
    if (pos + n > bytes.length) throw const FormatException('Sample ends early');
  }

  int u32() {
    align(4);
    need(4);
    final v = data.getUint32(pos, endian);
    pos += 4;
    return v;
  }

  Map<String, dynamic> message(CdrCodec codec, RosMessageSpec spec) {
    if (spec.fields.isEmpty) {
      // rosidl gives empty messages one uint8 member ("structure_needs_at_least_one_member").
      need(1);
      pos += 1;
      return <String, dynamic>{};
    }
    final out = <String, dynamic>{};
    for (final f in spec.fields) {
      if (f.arrayLen < 0) {
        out[f.name] = value(codec, f.type);
      } else {
        out[f.name] = array(codec, f.type, f.arrayLen == 0 ? u32() : f.arrayLen);
      }
    }
    return out;
  }

  Object? array(CdrCodec codec, String type, int count) {
    switch (type) {
      case 'uint8' || 'byte' || 'char':
        need(count);
        final v = Uint8List.fromList(Uint8List.sublistView(bytes, pos, pos + count));
        pos += count;
        return v;
      case 'int8':
        need(count);
        final v = Int8List.fromList(Int8List.sublistView(bytes, pos, pos + count));
        pos += count;
        return v;
      case 'bool':
        need(count);
        final v = [for (var i = 0; i < count; i++) bytes[pos + i] != 0];
        pos += count;
        return v;
    }
    return [for (var i = 0; i < count; i++) value(codec, type)];
  }

  Object? value(CdrCodec codec, String type) {
    switch (type) {
      case 'bool':
        need(1);
        return bytes[pos++] != 0;
      case 'uint8' || 'byte' || 'char':
        need(1);
        return bytes[pos++];
      case 'int8':
        need(1);
        return data.getInt8(pos++);
      case 'int16':
        align(2); need(2);
        final v = data.getInt16(pos, endian); pos += 2; return v;
      case 'uint16':
        align(2); need(2);
        final v = data.getUint16(pos, endian); pos += 2; return v;
      case 'int32':
        align(4); need(4);
        final v = data.getInt32(pos, endian); pos += 4; return v;
      case 'uint32':
        return u32();
      case 'int64':
        align(8); need(8);
        final v = data.getInt64(pos, endian); pos += 8; return v;
      case 'uint64':
        align(8); need(8);
        final v = data.getUint64(pos, endian); pos += 8; return v;
      case 'float32':
        align(4); need(4);
        final v = data.getFloat32(pos, endian); pos += 4;
        return v.isFinite ? v : null;
      case 'float64':
        align(8); need(8);
        final v = data.getFloat64(pos, endian); pos += 8;
        return v.isFinite ? v : null;
      case 'string':
        final n = u32();
        need(n);
        final end = n > 0 && bytes[pos + n - 1] == 0 ? pos + n - 1 : pos + n;
        final s = utf8.decode(Uint8List.sublistView(bytes, pos, end), allowMalformed: true);
        pos += n;
        return s;
      case 'wstring':
        final n = u32();
        final units = <int>[];
        for (var i = 0; i < n; i++) {
          align(2); need(2);
          units.add(data.getUint16(pos, endian));
          pos += 2;
        }
        if (units.isNotEmpty && units.last == 0) units.removeLast();
        return String.fromCharCodes(units);
    }
    return message(codec, codec._spec(type));
  }
}

class _Writer {
  var _bytes = Uint8List(256);
  late var _data = ByteData.sublistView(_bytes);
  int pos = 4;

  _Writer() {
    _bytes[1] = 1; // CDR little endian
  }

  Uint8List take() => Uint8List.sublistView(_bytes, 0, pos);

  void reserve(int n) {
    if (pos + n <= _bytes.length) return;
    var size = _bytes.length * 2;
    while (size < pos + n) {
      size *= 2;
    }
    _bytes = Uint8List(size)..setRange(0, pos, _bytes);
    _data = ByteData.sublistView(_bytes);
  }

  void align(int n) {
    final rel = (pos - 4) % n;
    if (rel != 0) {
      reserve(n - rel);
      pos += n - rel; // fresh buffer bytes are already zero
    }
  }

  void u32(int v) {
    align(4);
    reserve(4);
    _data.setUint32(pos, v, Endian.little);
    pos += 4;
  }

  void message(CdrCodec codec, RosMessageSpec spec, Object? msg) {
    final map = msg is Map ? msg : const {};
    if (spec.fields.isEmpty) {
      reserve(1);
      pos += 1;
      return;
    }
    for (final f in spec.fields) {
      final v = map[f.name] ?? _legacyAlias(map, f.name);
      if (f.arrayLen < 0) {
        // A field that is left out takes its default (0.0 for floats). An explicit null stays null,
        // which for a float means NaN, as in rosbridge's JSON.
        final missing = !map.containsKey(f.name) && _legacyAlias(map, f.name) == null;
        value(codec, f.type, v ?? _parseDefault(f) ?? (missing ? _zero(f.type) : null));
        continue;
      }
      final list = _asList(f.type, v);
      final count = f.arrayLen == 0 ? list.length : f.arrayLen;
      if (f.arrayLen == 0) u32(count);
      if (list is Uint8List && {'uint8', 'byte', 'char', 'int8'}.contains(f.type)) {
        reserve(count);
        _bytes.setRange(pos, pos + (list.length < count ? list.length : count), list);
        pos += count;
        continue;
      }
      for (var i = 0; i < count; i++) {
        value(codec, f.type, i < list.length ? list[i] : _zero(f.type)); // short fixed arrays: pad with defaults
      }
    }
  }

  /// ROS 1 spellings of the time fields, which some saved messages still use.
  static Object? _legacyAlias(Map map, String name) =>
      name == 'sec' ? map['secs'] : name == 'nanosec' ? map['nsecs'] : null;

  static List _asList(String type, Object? v) {
    if (v == null) return const [];
    if (v is String && {'uint8', 'byte', 'char'}.contains(type)) return base64Decode(v);
    if (v is List) return v;
    throw FormatException('Expected a list of $type');
  }

  static const _floatTypes = {'float32', 'float64', 'float', 'double'};

  /// The default of a field that was left out: 0.0 for floats (null would encode NaN), null otherwise
  /// (integers, booleans, strings and messages already default to zero values from null).
  static Object? _zero(String type) => _floatTypes.contains(type) ? 0.0 : null;

  static Object? _parseDefault(RosField f) {
    final d = f.defaultValue;
    if (d == null) return null;
    if (f.type == 'string' || f.type == 'wstring') {
      return d.length >= 2 && (d[0] == '"' || d[0] == "'") ? d.substring(1, d.length - 1) : d;
    }
    if (f.type == 'bool') return d == 'true' || d == 'True' || d == '1';
    return num.tryParse(d);
  }

  void value(CdrCodec codec, String type, Object? v) {
    switch (type) {
      case 'bool':
        reserve(1);
        _bytes[pos++] = (v == true || (v is num && v != 0)) ? 1 : 0;
        return;
      case 'uint8' || 'byte' || 'char' || 'int8':
        reserve(1);
        _bytes[pos++] = _int(v) & 0xff;
        return;
      case 'int16' || 'uint16':
        align(2); reserve(2);
        _data.setUint16(pos, _int(v) & 0xffff, Endian.little); pos += 2;
        return;
      case 'int32' || 'uint32':
        align(4); reserve(4);
        _data.setUint32(pos, _int(v) & 0xffffffff, Endian.little); pos += 4;
        return;
      case 'int64' || 'uint64':
        align(8); reserve(8);
        _data.setInt64(pos, _int(v), Endian.little); pos += 8;
        return;
      case 'float32':
        align(4); reserve(4);
        _data.setFloat32(pos, _double(v), Endian.little); pos += 4;
        return;
      case 'float64':
        align(8); reserve(8);
        _data.setFloat64(pos, _double(v), Endian.little); pos += 8;
        return;
      case 'string':
        final b = utf8.encode(v == null ? '' : '$v');
        u32(b.length + 1);
        reserve(b.length + 1);
        _bytes.setRange(pos, pos + b.length, b);
        pos += b.length + 1;
        return;
      case 'wstring':
        final units = (v == null ? '' : '$v').codeUnits;
        u32(units.length + 1);
        for (final u in [...units, 0]) {
          align(2); reserve(2);
          _data.setUint16(pos, u, Endian.little); pos += 2;
        }
        return;
    }
    message(codec, codec._spec(type), v);
  }

  static int _int(Object? v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is bool) return v ? 1 : 0;
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? (throw FormatException('Expected an integer, got $v'));
  }

  static double _double(Object? v) {
    if (v == null) return double.nan; // rosbridge's JSON null for NaN/inf
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? (throw FormatException('Expected a number, got $v'));
  }
}
