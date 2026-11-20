import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/ros_connection.dart';

void main() {
  test('invalid host and port are rejected before connecting', () {
    for (final port in ['', '0', '65536', 'abc']) {
      expect(() => robotUri('localhost', port), throwsFormatException);
    }
    expect(() => robotUri('host/path', '9090'), throwsFormatException);
    expect(robotUri('localhost', '9090').port, 9090);
  });

  test('supports secure WebSocket URLs, reverse-proxy paths and URL ports', () {
    expect(robotUri('wss://robot.example:9443/rosbridge', '9090').toString(),
        'wss://robot.example:9443/rosbridge');
    expect(robotUri('ws://robot.example/rosbridge', '8080').toString(),
        'ws://robot.example:8080/rosbridge');
    expect(robotHost('wss://robot.example:9443/rosbridge'), 'robot.example');
    expect(() => robotUri('wss://user:pass@robot.example/path', '9090'), throwsFormatException);
  });

  late HttpServer server;
  late RosConnection client;
  late WebSocket peer;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<WebSocket>();
    server.listen((request) async {
      accepted.complete(await WebSocketTransformer.upgrade(request));
    });
    client = RosConnection('127.0.0.1', '${server.port}',
        timeout: const Duration(milliseconds: 500));
    await client.ready;
    peer = await accepted.future;
  });
  tearDown(() async {
    client.close();
    await peer.close();
    await server.close(force: true);
  });

  test('concurrent service responses are matched by id', () async {
    final requests = <Map<String, dynamic>>[];
    peer.listen((event) {
      requests.add(jsonDecode(event as String) as Map<String, dynamic>);
      if (requests.length == 2) {
        for (final request in requests.reversed) {
          peer.add(jsonEncode({'op': 'service_response', 'id': request['id'],
            'result': true, 'values': {'service': request['service']}}));
        }
      }
    });
    final results = await Future.wait([client.call('/first'), client.call('/second')]);
    expect(results[0]['service'], '/first');
    expect(results[1]['service'], '/second');
  });

  test('unanswered service calls time out', () async {
    peer.listen((_) {});
    await expectLater(client.call('/silent'), throwsA(isA<TimeoutException>()));
  });

  test('informational status does not consume a service response', () async {
    peer.listen((event) {
      final request = jsonDecode(event as String) as Map;
      peer.add(jsonEncode({'op': 'status', 'id': request['id'], 'level': 'info'}));
      peer.add(jsonEncode({'op': 'service_response', 'id': request['id'],
        'result': true, 'values': {'nodes': ['/robot']}}));
    });
    expect((await client.call('/rosapi/nodes'))['nodes'], ['/robot']);
  });

  test('server rejection is surfaced to the service caller', () async {
    peer.listen((event) {
      final request = jsonDecode(event as String) as Map;
      peer.add(jsonEncode({'op': 'service_response', 'id': request['id'],
        'result': false, 'values': {}}));
    });
    await expectLater(client.call('/missing'), throwsStateError);
  });

  test('server disconnect fails pending service calls', () async {
    peer.listen((_) => peer.close());
    await expectLater(client.call('/closed'), throwsStateError);
    expect(client.isClosed, isTrue);
  });

  test('malformed JSON does not stop subsequent valid messages', () async {
    final received = client.messages.first;
    peer.add('invalid JSON');
    peer.add(jsonEncode({'op': 'publish', 'topic': '/test', 'msg': {'data': 1}}));
    expect((await received)['topic'], '/test');
  });

  test('a socket that stays open but goes silent is closed as a lost link', () async {
    final done = Completer<void>();
    client.messages.listen((_) {}, onDone: done.complete);
    for (var i = 0; i < 15; i++) {
      peer.add(jsonEncode({'op': 'publish', 'topic': '/odom', 'msg': {'i': i}}));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(client.isClosed, isFalse, reason: 'steady data is a healthy link');
    await done.future.timeout(const Duration(seconds: 4)); // the peer keeps the socket open but sends nothing
    expect(client.lastError, startsWith('Lost contact with the robot'));
  });

  test('maps are asked for PNG-compressed and arrive as the usual publish message', () async {
    final sent = <Map<String, dynamic>>[];
    peer.listen((event) => sent.add(jsonDecode(event as String) as Map<String, dynamic>));
    client.send({'op': 'subscribe', 'topic': '/map', 'type': 'nav_msgs/msg/OccupancyGrid'});
    client.send({'op': 'subscribe', 'topic': '/odom', 'type': 'nav_msgs/msg/Odometry'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(sent.firstWhere((m) => m['topic'] == '/map')['compression'], 'png');
    expect(sent.firstWhere((m) => m['topic'] == '/odom').containsKey('compression'), isFalse,
        reason: 'small, frequent messages stay plain');

    final map = {'op': 'publish', 'topic': '/map', 'msg': {'info': {'width': 300, 'height': 200},
      'data': List.filled(60000, 0)..[123] = 100}};
    final received = client.messages.first;
    peer.add(jsonEncode({'op': 'png', 'data': await rosbridgePng(jsonEncode(map))}));
    final message = await received.timeout(const Duration(seconds: 10));
    expect(message['topic'], '/map');
    expect((message['msg']['data'] as List)[123], 100);
    expect((message['msg']['data'] as List).length, 60000);
  });
}

/// What rosbridge sends for `compression: png`: the UTF-8 text in the RGB pixels of a PNG, padded with
/// newlines (rosbridge_library/internal/pngcompression.py), base64.
Future<String> rosbridgePng(String text) async {
  final bytes = utf8.encode(text);
  final width = math.sqrt(bytes.length / 3).floor();
  final height = (bytes.length / 3 / width).ceil();
  final padded = Uint8List(width * height * 3)..fillRange(0, width * height * 3, 0x0a)..setAll(0, bytes);
  final rgba = Uint8List(width * height * 4);
  for (var i = 0, j = 0; i < padded.length; i += 3, j += 4) {
    rgba[j] = padded[i]; rgba[j + 1] = padded[i + 1]; rgba[j + 2] = padded[i + 2]; rgba[j + 3] = 255;
  }
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, done.complete);
  final image = await done.future;
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  return base64Encode(png!.buffer.asUint8List());
}
