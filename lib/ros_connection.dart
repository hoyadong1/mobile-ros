import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:web_socket_channel/web_socket_channel.dart';
import 'link_watch.dart';
import 'relay_access.dart';

Uri robotUri(String host, String port) {
  final input = host.trim();
  if (RelayAccess.isRelay(input)) {
    final relay = Uri.parse(input);
    return relay.replace(path: relay.path.replaceAll(RegExp(r'/$'), ''));
  }
  if (input.startsWith(RegExp(r'^wss?://', caseSensitive: false))) {
    final address = Uri.tryParse(input);
    final authority = input.split('://').last.split(RegExp(r'[/?#]')).first;
    final explicitPort = RegExp(r':([0-9]+)$').firstMatch(authority)?.group(1);
    final number = explicitPort != null ? int.tryParse(explicitPort)
        : address?.hasPort == true ? address!.port : int.tryParse(port);
    if (address == null || !{'ws', 'wss'}.contains(address.scheme.toLowerCase()) ||
        address.host.isEmpty || address.userInfo.isNotEmpty || address.hasFragment ||
        number == null || number < 1 || number > 65535) {
      throw const FormatException('Enter a valid ws:// or wss:// robot URL and port.');
    }
    return Uri(scheme: address.scheme.toLowerCase(), host: address.host, port: number,
        path: address.path, query: address.hasQuery ? address.query : null);
  }
  final number = int.tryParse(port);
  if (input.isEmpty || input.contains(RegExp(r'[\s:/?#@]')) ||
      number == null || number < 1 || number > 65535) {
    throw const FormatException('Enter a valid host and port (1–65535).');
  }
  return Uri(scheme: 'ws', host: input, port: number);
}

/// Hostname used for companion HTTP/RTSP camera endpoints when a full rosbridge URL was entered.
String robotHost(String host) {
  final input = host.trim();
  final address = Uri.tryParse(input);
  return address != null && {'ws', 'wss'}.contains(address.scheme.toLowerCase()) && address.host.isNotEmpty
      ? address.host : input;
}

/// Occupancy grids are megabytes of JSON digits (a 200 m site at 5 cm is 34 MB); while one crosses Wi-Fi
/// nothing else arrives, and the link watch takes the quiet for a lost robot. rosbridge can send them
/// PNG-compressed (`compression: png`), which shrinks the repetitive digits to a small fraction.
bool compressesWell(Map<String, dynamic> subscribe) {
  final type = '${subscribe['type'] ?? ''}';
  final topic = '${subscribe['topic'] ?? ''}';
  return type.endsWith('OccupancyGrid') || RegExp(r'(^|/)(map|costmap)$').hasMatch(topic);
}

/// Undoes rosbridge's `png` compression: the message's UTF-8 bytes were packed into the RGB pixels of a
/// PNG, padded with newlines. The PNG is decoded by the engine; the bytes and JSON on another isolate.
Future<Map<String, dynamic>?> inflatePngMessage(String base64Png) async {
  final codec = await ui.instantiateImageCodec(base64Decode(base64Png));
  final frame = await codec.getNextFrame();
  codec.dispose();
  final rgba = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
  frame.image.dispose();
  if (rgba == null) return null;
  final pixels = rgba.buffer.asUint8List(rgba.offsetInBytes, rgba.lengthInBytes);
  return Isolate.run(() {
    final text = Uint8List(pixels.length ~/ 4 * 3);
    var j = 0;
    for (var i = 0; i < pixels.length; i += 4) {
      text[j++] = pixels[i];
      text[j++] = pixels[i + 1];
      text[j++] = pixels[i + 2];
    }
    var end = text.length;
    while (end > 0 && text[end - 1] == 0x0a) {
      end--;
    }
    final decoded = jsonDecode(utf8.decode(Uint8List.sublistView(text, 0, end)));
    return decoded is Map<String, dynamic> ? decoded : null;
  });
}

/// How the app talks to a robot: rosbridge v2 messages (`op`: subscribe, publish, …) out, events in,
/// and service calls. [RosBridgeConnection] sends them over rosbridge's WebSocket; the direct ROS 2
/// connection (lib/dds) carries the same messages over DDS.
abstract class RosConnection {
  factory RosConnection(String ip, String port, {Duration timeout}) = RosBridgeConnection;

  Stream<Map<String, dynamic>> get messages;
  bool get isClosed;
  String? get lastError;
  Duration get timeout;
  Future<void> get ready;
  void send(Map<String, dynamic> message);
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]);
  void close();
}

/// One listener per socket, with bounded service requests and owned cleanup.
class RosBridgeConnection implements RosConnection {
  final WebSocketChannel channel;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<dynamic> _subscription;
  bool _closed = false;
  int _nextId = 0;
  @override
  String? lastError;
  @override
  final Duration timeout;

  /// A dropped Wi-Fi link can leave the WebSocket open but silent for minutes. When every topic that
  /// arrived steadily stops at once, the connection is treated as lost and closed, as a closed socket is.
  final linkWatch = LinkWatch();
  Timer? _linkTimer;

  RosBridgeConnection(String ip, String port, {this.timeout = const Duration(seconds: 8)})
      : channel = _open(robotUri(ip, port)) {
    _subscription = channel.stream.listen((event) {
      try {
        final decoded = jsonDecode(event as String);
        if (decoded is! Map<String, dynamic>) return;
        if (decoded['op'] == 'png' && decoded['data'] is String) {
          // A compressed map: handled like any message once inflated (a moment later).
          inflatePngMessage(decoded['data'] as String).then((inner) {
            if (inner != null && !_closed) _receive(inner);
          }, onError: (Object e) { lastError = 'Could not read a compressed message: $e'; });
          return;
        }
        _receive(decoded);
      } catch (error) {
        lastError = 'Invalid server message: $error';
      }
    }, onError: (Object error) => _fail(error),
      onDone: () => _fail(StateError('Robot connection closed.')));
    _linkTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final now = DateTime.now();
      if (!linkWatch.silent(now)) return;
      final reason = lostContactMessage(linkWatch.quietFor(now));
      _fail(StateError(reason));
      lastError = reason;
      _subscription.cancel();
      channel.sink.close();
    });
  }

  void _receive(Map<String, dynamic> decoded) {
      try {
        if (decoded['op'] == 'publish' && decoded['topic'] is String) {
          linkWatch.sample(decoded['topic'] as String, DateTime.now());
        }
        final isFailure = decoded['result'] == false || decoded['level'] == 'error';
        final pending = decoded['op'] == 'service_response' || isFailure
            ? _pending.remove(decoded['id']) : null;
        if (pending != null) {
          if (isFailure) {
            pending.completeError(StateError(decoded.toString()));
          } else {
            pending.complete(decoded);
          }
        }
        if (!_messages.isClosed) _messages.add(decoded);
      } catch (error) {
        lastError = 'Invalid server message: $error';
      }
  }

  /// A relay address carries the user's token as a subprotocol; a robot's own rosbridge needs none.
  static WebSocketChannel _open(Uri uri) {
    final protocols = RelayAccess.isRelay(uri.toString()) ? RelayAccess.protocolsFor(uri) : null;
    return WebSocketChannel.connect(uri, protocols: protocols);
  }

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  bool get isClosed => _closed;

  @override
  Future<void> get ready async {
    try {
      await channel.ready.timeout(timeout);
      if (_closed) throw StateError(lastError ?? 'Connection closed');
    } catch (_) {
      close();
      rethrow;
    }
  }

  @override
  void send(Map<String, dynamic> message) {
    if (_closed) throw StateError(lastError ?? 'Connection closed');
    if (message['op'] == 'unsubscribe' && message['topic'] is String) linkWatch.forget(message['topic'] as String);
    if (message['op'] == 'subscribe' && message['compression'] == null && compressesWell(message)) {
      message = {...message, 'compression': 'png'};
    }
    channel.sink.add(jsonEncode(message));
  }

  @override
  Future<Map<String, dynamic>> call(String service,
      [Map<String, dynamic> args = const {}]) async {
    await ready;
    final id = 'request_${_nextId++}';
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    try {
      send({'op': 'call_service', 'id': id, 'service': service, 'args': args});
      final response = await completer.future.timeout(timeout);
      final values = response['values'];
      if (values is! Map<String, dynamic>) {
        throw const FormatException('Missing service response values');
      }
      return values;
    } finally {
      _pending.remove(id);
    }
  }

  void _fail(Object error) {
    if (_closed) return;
    _closed = true;
    _linkTimer?.cancel();
    lastError = error.toString();
    for (final pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _messages.close();
  }

  @override
  void close() {
    _fail(StateError('Connection closed'));
    _subscription.cancel();
    channel.sink.close();
  }
}
