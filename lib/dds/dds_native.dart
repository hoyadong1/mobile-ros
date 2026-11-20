/// Dart FFI bindings to libmobileros_dds (native/dds/mobileros_dds.c).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// One discovered DDS endpoint (a ROS publisher, subscription, service server or client).
class DdsEndpoint {
  const DdsEndpoint({required this.isWriter, required this.guid, required this.participant,
      required this.topic, required this.type, required this.reliable, required this.transientLocal});
  final bool isWriter;
  final String guid;
  final String participant;
  final String topic;
  final String type;
  final bool reliable;
  final bool transientLocal;
}

class DdsGraph {
  const DdsGraph(this.participants, this.endpoints);
  static const empty = DdsGraph({}, []);

  /// Participant GUID → whether it is a Fast DDS participant (they do services differently).
  final Map<String, bool> participants;
  final List<DdsEndpoint> endpoints;

  static DdsGraph parse(String text) {
    final participants = <String, bool>{};
    final endpoints = <DdsEndpoint>[];
    for (final line in text.split('\n')) {
      final f = line.split('\t');
      if (f.length == 3 && f[0] == 'P') {
        participants[f[1]] = f[2] == 'fastdds';
      } else if (f.length == 7 && (f[0] == 'W' || f[0] == 'R')) {
        endpoints.add(DdsEndpoint(isWriter: f[0] == 'W', guid: f[1], participant: f[2], topic: f[3],
            type: f[4], reliable: f[5] == '1', transientLocal: f[6] == '1'));
      }
    }
    return DdsGraph(participants, endpoints);
  }
}

class DdsException implements Exception {
  DdsException(this.what, this.code, [this.detail]);
  final String what;
  final int code;
  final String? detail;
  @override
  String toString() => 'DDS $what failed (${detail ?? code})';
}

/// A received sample: the CDR bytes and the GUID (hex) of the writer that sent it.
typedef DdsSample = ({Uint8List data, String writer});

class DdsNative {
  DdsNative._(DynamicLibrary lib)
      : _open = lib.lookupFunction<Int32 Function(Uint32, Pointer<Utf8>), int Function(int, Pointer<Utf8>)>('mr_open'),
        _close = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('mr_close'),
        _guid = lib.lookupFunction<Int32 Function(Int32, Pointer<Uint8>), int Function(int, Pointer<Uint8>)>('mr_guid'),
        _reader = lib.lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32),
            int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int)>('mr_reader'),
        _writer = lib.lookupFunction<Int32 Function(Int32, Pointer<Utf8>, Pointer<Utf8>, Int32, Int32, Int32),
            int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int)>('mr_writer'),
        _delete = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('mr_delete'),
        _matched = lib.lookupFunction<Int32 Function(Int32), int Function(int)>('mr_matched'),
        _write = lib.lookupFunction<Int32 Function(Int32, Pointer<Uint8>, Uint32), int Function(int, Pointer<Uint8>, int)>('mr_write'),
        _take = lib.lookupFunction<Int32 Function(Int32, Pointer<Pointer<Uint8>>, Pointer<Uint8>, Pointer<Int64>),
            int Function(int, Pointer<Pointer<Uint8>>, Pointer<Uint8>, Pointer<Int64>)>('mr_take'),
        _free = lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('mr_free'),
        _graph = lib.lookupFunction<Int32 Function(Int32, Pointer<Pointer<Utf8>>), int Function(int, Pointer<Pointer<Utf8>>)>('mr_graph'),
        _errorText = lib.lookupFunction<Pointer<Utf8> Function(Int32), Pointer<Utf8> Function(int)>('mr_error_text');

  static DdsNative? _instance;
  static Object? loadError;

  /// The native library, or null where it is not available (desktop tests, unsupported ABI).
  static DdsNative? load() {
    if (_instance != null || loadError != null) return _instance;
    try {
      if (!Platform.isAndroid) throw UnsupportedError('Direct ROS 2 connection is available on Android only');
      return _instance = DdsNative._(DynamicLibrary.open('libmobileros_dds.so'));
    } catch (error) {
      loadError = error;
      return null;
    }
  }

  final int Function(int, Pointer<Utf8>) _open;
  final int Function(int) _close;
  final int Function(int, Pointer<Uint8>) _guid;
  final int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int) _reader;
  final int Function(int, Pointer<Utf8>, Pointer<Utf8>, int, int, int) _writer;
  final int Function(int) _delete;
  final int Function(int) _matched;
  final int Function(int, Pointer<Uint8>, int) _write;
  final int Function(int, Pointer<Pointer<Uint8>>, Pointer<Uint8>, Pointer<Int64>) _take;
  final void Function(Pointer<Void>) _free;
  final int Function(int, Pointer<Pointer<Utf8>>) _graph;
  final Pointer<Utf8> Function(int) _errorText;

  int _check(String what, int rc) {
    if (rc < 0) throw DdsException(what, rc, _errorText(rc).toDartString());
    return rc;
  }

  int open(int domain, String config) => using((a) => _check('join domain $domain', _open(domain, config.toNativeUtf8(allocator: a))));
  void close(int participant) => _close(participant);
  void delete(int entity) => _delete(entity);

  /// Number of remote endpoints a reader or writer is matched with.
  int matched(int entity) => _check('matched', _matched(entity));

  String guid(int entity) => using((a) {
        final buf = a<Uint8>(16);
        _check('guid', _guid(entity, buf));
        return _hex(buf.asTypedList(16));
      });

  int reader(int participant, String topic, String type, {required bool reliable, required bool transientLocal, int depth = 10}) =>
      using((a) => _check('subscribe $topic', _reader(participant, topic.toNativeUtf8(allocator: a),
          type.toNativeUtf8(allocator: a), reliable ? 1 : 0, transientLocal ? 1 : 0, depth)));

  int writer(int participant, String topic, String type, {bool reliable = true, bool transientLocal = false, int depth = 10}) =>
      using((a) => _check('advertise $topic', _writer(participant, topic.toNativeUtf8(allocator: a),
          type.toNativeUtf8(allocator: a), reliable ? 1 : 0, transientLocal ? 1 : 0, depth)));

  void write(int writer, Uint8List data) => using((a) {
        final buf = a<Uint8>(data.length);
        buf.asTypedList(data.length).setAll(0, data);
        _check('publish', _write(writer, buf, data.length));
      });

  /// The next waiting sample, or null. [withWriter] also resolves the sending writer's GUID.
  DdsSample? take(int reader, {bool withWriter = false}) => using((a) {
        final out = a<Pointer<Uint8>>();
        final writer = withWriter ? a<Uint8>(16) : nullptr;
        final n = _check('read', _take(reader, out, writer, nullptr));
        if (n == 0) return null;
        final data = Uint8List.fromList(out.value.asTypedList(n));
        _free(out.value.cast());
        return (data: data, writer: withWriter ? _hex(writer.asTypedList(16)) : '');
      });

  DdsGraph graph(int participant) => using((a) {
        final out = a<Pointer<Utf8>>();
        _check('discovery', _graph(participant, out));
        final text = out.value.toDartString();
        _free(out.value.cast());
        return DdsGraph.parse(text);
      });

  static String _hex(Uint8List bytes) => [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();
}
