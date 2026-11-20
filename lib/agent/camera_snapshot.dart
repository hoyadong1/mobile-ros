import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import '../ros_client.dart';
import '../ros_image.dart';

/// One camera frame as an encoded image a language model can look at.
class CameraSnapshot {
  const CameraSnapshot(this.bytes, this.mimeType, {this.width, this.height});

  final Uint8List bytes;
  /// `image/jpeg` or `image/png`.
  final String mimeType;
  final int? width, height;
}

/// Takes the next frame from [topic] (sensor_msgs/CompressedImage or sensor_msgs/Image) and returns it
/// encoded: compressed frames as they are, raw frames converted to PNG. Throws a [TimeoutException] if
/// no frame arrives within [timeout], or a [FormatException] for a frame that is not a colour image.
Future<CameraSnapshot> takeSnapshot(RosClient ros, String topic,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final msg = await ros.subscribe(topic, queueLength: 1).first.timeout(timeout);
  if (isCompressedImage(msg)) {
    final format = (msg['format'] as String).toLowerCase();
    if (format.contains('compresseddepth')) throw const FormatException('This camera topic carries depth, not colour');
    final raw = msg['data'];
    final bytes = raw is String ? base64Decode(raw) : raw is List ? Uint8List.fromList(raw.cast<int>()) : null;
    if (bytes == null || bytes.isEmpty) throw const FormatException('Empty camera frame');
    return CameraSnapshot(bytes, format.contains('png') ? 'image/png' : 'image/jpeg');
  }
  final frame = decodeRosImage(msg);
  final png = await _png(frame);
  return CameraSnapshot(png, 'image/png', width: frame.width, height: frame.height);
}

Future<Uint8List> _png(RgbaFrame frame) {
  final done = Completer<Uint8List>();
  ui.decodeImageFromPixels(frame.pixels, frame.width, frame.height, ui.PixelFormat.rgba8888, (image) async {
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw const FormatException('Could not encode the camera frame');
      done.complete(data.buffer.asUint8List());
    } catch (e) {
      done.completeError(e);
    } finally {
      image.dispose();
    }
  });
  return done.future;
}
