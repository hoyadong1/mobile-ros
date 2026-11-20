import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/mjpeg.dart';
import 'package:ros_tester/robot_profile.dart';

/// A tiny fake "JPEG": SOI, payload, EOI.
Uint8List jpeg(int id) => Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, id, id, 0xFF, 0xD9]);

/// The part framing web_video_server uses.
List<int> part(Uint8List frame) => [
  ...'--boundarydonotcross\r\nContent-Type: image/jpeg\r\nContent-Length: ${frame.length}\r\n\r\n'.codeUnits,
  ...frame, ...'\r\n'.codeUnits,
];

void main() {
  test('frames split into chunks of any size, markers straddling chunks, come out whole and in order', () {
    List<int> frame(int n) => [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(n, n & 0x7F), 0xFF, 0xD9];
    final frames = [frame(10), frame(300), frame(5)];
    final stream = <int>[
      for (final f in frames) ...[...'--b\r\nContent-Type: image/jpeg\r\n\r\n'.codeUnits, ...f, 13, 10],
    ];
    for (final size in [1, 2, 3, 7, 64, stream.length]) {
      final splitter = JpegFrameSplitter();
      final got = <List<int>>[];
      for (var i = 0; i < stream.length; i += size) {
        got.addAll(splitter.add(stream.sublist(i, i + size > stream.length ? stream.length : i + size)));
      }
      expect(got, frames, reason: 'chunk size $size');
    }
  });

  test('splitter finds frames across arbitrary chunk boundaries and ignores part headers', () {
    final stream = [for (var i = 1; i <= 3; i++) ...part(jpeg(i))];
    for (final chunkSize in [1, 2, 3, 7, 64]) {
      final splitter = JpegFrameSplitter();
      final frames = <Uint8List>[];
      for (var i = 0; i < stream.length; i += chunkSize) {
        frames.addAll(splitter.add(stream.sublist(i, (i + chunkSize).clamp(0, stream.length))));
      }
      expect(frames.map((f) => f[4]).toList(), [1, 2, 3], reason: 'chunk size $chunkSize');
      expect(frames.first, jpeg(1));
    }
  });

  test('splitter drops an oversized broken frame and recovers', () {
    final splitter = JpegFrameSplitter(maxBuffer: 64);
    expect(splitter.add([0xFF, 0xD8, 0xFF, ...List.filled(100, 1)]), isEmpty); // never ends
    expect(splitter.add(part(jpeg(9))).single[4], 9);
  });

  test('web_video_server URL', () {
    expect(webVideoServerUrl('192.168.0.5', '/camera/image_raw'),
        'http://192.168.0.5:8080/stream?topic=/camera/image_raw&type=mjpeg&quality=80',
        reason: 'web_video_server does not percent-decode the topic');
    expect(Uri.parse(webVideoServerUrl('r', '/a/b')).query, 'topic=/a/b&type=mjpeg&quality=80',
        reason: 'Uri.parse keeps the slashes literal when the client sends it');
  });

  test('client reads an HTTP multipart stream and reconnects after the server drops it', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var connections = 0;
    server.listen((request) async {
      connections++;
      request.response.headers.set('Content-Type', 'multipart/x-mixed-replace;boundary=boundarydonotcross');
      for (var i = 1; i <= 2; i++) {
        request.response.add(part(jpeg(connections * 10 + i)));
        await request.response.flush();
      }
      await request.response.close(); // drop the stream: the client must come back
    });
    final frames = <int>[];
    final errors = <Object>[];
    final gotFour = Completer<void>();
    final client = MjpegStream(Uri.parse('http://127.0.0.1:${server.port}/stream?topic=/cam'),
        onFrame: (f) { frames.add(f[4]); if (frames.length == 4 && !gotFour.isCompleted) gotFour.complete(); },
        onError: errors.add);
    addTearDown(client.stop);
    client.start();
    await gotFour.future.timeout(const Duration(seconds: 10));
    expect(frames.take(4).toList(), [11, 12, 21, 22], reason: 'frames from two connections');
    expect(errors, isNotEmpty, reason: 'the drop was reported');
  });

  group('MJPEG suggestion', () {
    const raw = {'topics': ['/cmd_vel', '/camera/image_raw'], 'types': ['geometry_msgs/msg/Twist', 'sensor_msgs/msg/Image']};
    test('raw images only + web_video_server -> MJPEG', () {
      final p = suggestProfile(raw, nodes: ['/web_video_server', '/rosapi'], host: '10.0.0.7');
      expect(p.cameraSource, CameraSource.mjpeg);
      expect(p.mjpegUrl, webVideoServerUrl('10.0.0.7', '/camera/image_raw'));
    });
    test('no web_video_server -> raw topic', () {
      expect(suggestProfile(raw, nodes: ['/rosapi'], host: '10.0.0.7').cameraSource, CameraSource.rosImage);
    });
    test('a compressed topic still wins over MJPEG', () {
      final p = suggestProfile({
        'topics': ['/camera/image_raw', '/camera/image_raw/compressed'],
        'types': ['sensor_msgs/msg/Image', 'sensor_msgs/msg/CompressedImage'],
      }, nodes: ['/web_video_server'], host: '10.0.0.7');
      expect(p.cameraSource, CameraSource.rosImage);
      expect(p.cameraTopic, '/camera/image_raw/compressed');
    });
  });

  test('profiles keep the MJPEG URL, and older saved profiles without it still load', () {
    final p = RobotProfile.defaults(DriveType.differential)
        .copyWith(cameraSource: CameraSource.mjpeg, mjpegUrl: 'http://r:8080/stream?topic=/c');
    expect(RobotProfile.fromJson(p.toJson())!.mjpegUrl, 'http://r:8080/stream?topic=/c');
    final old = RobotProfile.defaults(DriveType.differential).toJson()..remove('mjpegUrl');
    expect(RobotProfile.fromJson(old)!.mjpegUrl, '');
  });
}
