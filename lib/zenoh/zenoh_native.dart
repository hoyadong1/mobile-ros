/// Dart FFI bindings to libmobileros_zenoh (native/zenoh/mobileros_zenoh.c, zenoh-pico 1.8.0).
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'zenoh_connection.dart';

final class _MzEvent extends Struct {
  @Int32()
  external int kind;
  @Int32()
  external int id;
  external Pointer<Utf8> key;
  external Pointer<Uint8> payload;
  @Int32()
  external int payloadLen;
  external Pointer<Uint8> attachment;
  @Int32()
  external int attachmentLen;
}

typedef _OpenC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _OpenD = int Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _HC = Void Function(Int32);
typedef _HD = void Function(int);
typedef _HIdC = Void Function(Int32, Int32);
typedef _HIdD = void Function(int, int);
typedef _ZidC = Int32 Function(Int32, Pointer<Utf8>, Int32);
typedef _ZidD = int Function(int, Pointer<Utf8>, int);
typedef _SubC = Int32 Function(Int32, Pointer<Utf8>, Int32, Int32);
typedef _SubD = int Function(int, Pointer<Utf8>, int, int);
typedef _PutC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32, Pointer<Uint8>, Int32);
typedef _PutD = int Function(int, Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _QueryC = Int32 Function(Int32, Pointer<Utf8>, Pointer<Uint8>, Int32, Pointer<Uint8>, Int32, Int32, Int32);
typedef _QueryD = int Function(int, Pointer<Utf8>, Pointer<Uint8>, int, Pointer<Uint8>, int, int, int);
typedef _TokenC = Int32 Function(Int32, Pointer<Utf8>);
typedef _TokenD = int Function(int, Pointer<Utf8>);
typedef _PollC = Int32 Function(Int32, Pointer<_MzEvent>);
typedef _PollD = int Function(int, Pointer<_MzEvent>);
typedef _FreeC = Void Function(Pointer<_MzEvent>);
typedef _FreeD = void Function(Pointer<_MzEvent>);
typedef _ErrC = Pointer<Utf8> Function();

class _Lib {
  _Lib(DynamicLibrary l)
      : open = l.lookupFunction<_OpenC, _OpenD>('mz_open'),
        close = l.lookupFunction<_HC, _HD>('mz_close'),
        zid = l.lookupFunction<_ZidC, _ZidD>('mz_zid'),
        subscribe = l.lookupFunction<_SubC, _SubD>('mz_subscribe'),
        unsubscribe = l.lookupFunction<_HIdC, _HIdD>('mz_unsubscribe'),
        put = l.lookupFunction<_PutC, _PutD>('mz_put'),
        query = l.lookupFunction<_QueryC, _QueryD>('mz_query'),
        token = l.lookupFunction<_TokenC, _TokenD>('mz_token'),
        untoken = l.lookupFunction<_HIdC, _HIdD>('mz_untoken'),
        poll = l.lookupFunction<_PollC, _PollD>('mz_poll'),
        free = l.lookupFunction<_FreeC, _FreeD>('mz_event_free'),
        error = l.lookupFunction<_ErrC, _ErrC>('mz_error');

  final _OpenD open;
  final _HD close;
  final _ZidD zid;
  final _SubD subscribe;
  final _HIdD unsubscribe;
  final _PutD put;
  final _QueryD query;
  final _TokenD token;
  final _HIdD untoken;
  final _PollD poll;
  final _FreeD free;
  final _ErrC error;

  static _Lib? _instance;
  static String? loadError;

  /// The library for this platform, or null (then [loadError] says why).
  static _Lib? load() {
    if (_instance != null) return _instance;
    final candidates = Platform.isAndroid
        ? ['libmobileros_zenoh.so']
        : Platform.isWindows
            ? [
                ?Platform.environment['MOBILE_ROS_ZENOH_LIB'],
                'mobileros_zenoh.dll',
                'native/zenoh/prebuilt/windows-x64/mobileros_zenoh.dll', // flutter test from the repo
              ]
            : [
                ?Platform.environment['MOBILE_ROS_ZENOH_LIB'],
                'libmobileros_zenoh.so',
              ];
    for (final path in candidates) {
      try {
        return _instance = _Lib(DynamicLibrary.open(path));
      } catch (e) {
        loadError = '$e';
      }
    }
    return null;
  }
}

/// The native Zenoh session.
class NativeZenohBackend implements ZenohBackend {
  NativeZenohBackend._(this._lib, this._h);

  static NativeZenohBackend open(String locator) {
    final lib = _Lib.load();
    if (lib == null) {
      throw UnsupportedError('Zenoh is not available on this device (${_Lib.loadError}).');
    }
    final h = using((arena) => lib.open(locator.toNativeUtf8(allocator: arena), 'client'.toNativeUtf8(allocator: arena)));
    if (h < 0) throw StateError('Could not connect to the Zenoh router at $locator: ${lib.error().toDartString()}');
    return NativeZenohBackend._(lib, h);
  }

  final _Lib _lib;
  final int _h;
  final Pointer<_MzEvent> _event = calloc<_MzEvent>();
  bool _closed = false;

  @override
  String get zid => using((arena) {
    final buf = arena<Uint8>(64).cast<Utf8>();
    final n = _lib.zid(_h, buf, 64);
    return n > 0 ? buf.toDartString(length: n) : '';
  });

  StateError _failure(String what) => StateError('$what: ${_lib.error().toDartString()}');

  @override
  int subscribe(String keyexpr, {bool liveliness = false, bool history = false}) {
    final id = using((arena) =>
        _lib.subscribe(_h, keyexpr.toNativeUtf8(allocator: arena), liveliness ? 1 : 0, history ? 1 : 0));
    if (id < 0) throw _failure('Could not subscribe to $keyexpr');
    return id;
  }

  @override
  void unsubscribe(int id) => _lib.unsubscribe(_h, id);

  static Pointer<Uint8> _copy(Uint8List? data, Arena arena) {
    if (data == null || data.isEmpty) return nullptr;
    final p = arena<Uint8>(data.length);
    p.asTypedList(data.length).setAll(0, data);
    return p;
  }

  @override
  void put(String key, Uint8List payload, Uint8List attachment) {
    final r = using((arena) => _lib.put(_h, key.toNativeUtf8(allocator: arena), _copy(payload, arena),
        payload.length, _copy(attachment, arena), attachment.length));
    if (r < 0) throw _failure('Could not publish on $key');
  }

  @override
  int query(String key, {Uint8List? payload, Uint8List? attachment, Duration? timeout, bool liveliness = false}) {
    final id = using((arena) => _lib.query(_h, key.toNativeUtf8(allocator: arena), _copy(payload, arena),
        payload?.length ?? 0, _copy(attachment, arena), attachment?.length ?? 0, timeout?.inMilliseconds ?? 0,
        liveliness ? 1 : 0));
    if (id < 0) throw _failure('Could not query $key');
    return id;
  }

  @override
  int declareToken(String key) {
    final id = using((arena) => _lib.token(_h, key.toNativeUtf8(allocator: arena)));
    if (id < 0) throw _failure('Could not declare $key');
    return id;
  }

  @override
  void undeclareToken(int id) => _lib.untoken(_h, id);

  @override
  ZenohEvent? poll() {
    if (_closed || _lib.poll(_h, _event) == 0) return null;
    final e = _event.ref;
    Uint8List bytes(Pointer<Uint8> p, int n) => p == nullptr || n <= 0 ? Uint8List(0) : Uint8List.fromList(p.asTypedList(n));
    final event = ZenohEvent(e.kind, e.id,
        key: e.key == nullptr ? '' : e.key.toDartString(),
        payload: bytes(e.payload, e.payloadLen),
        attachment: bytes(e.attachment, e.attachmentLen));
    _lib.free(_event);
    return event;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    calloc.free(_event);
    // Closing waits for the session's read thread, which can sit in a socket read for up to the socket
    // timeout (1 s): do it off this isolate so leaving a robot never freezes the screen.
    final h = _h;
    Isolate.run(() => _Lib.load()?.close(h)).catchError((_) => _lib.close(h));
  }
}
