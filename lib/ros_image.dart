import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

class RgbaFrame {
  final Uint8List pixels;
  final int width, height;
  const RgbaFrame(this.pixels, this.width, this.height);
}

const supportedEncodings = ['rgb8', 'bgr8', 'rgba8', 'bgra8', 'mono8'];

/// Converts a rosbridge sensor_msgs/Image message to RGBA, honouring row padding (`step`).
/// Throws [FormatException] for unsupported or inconsistent images.
RgbaFrame decodeRosImage(Map msg) {
  final encoding = msg['encoding'];
  if (!supportedEncodings.contains(encoding)) throw FormatException('Unsupported image encoding: $encoding');
  final width = msg['width'] as int;
  final height = msg['height'] as int;
  final channels = encoding == 'mono8' ? 1 : (encoding == 'rgba8' || encoding == 'bgra8' ? 4 : 3);
  final step = msg['step'] as int? ?? width * channels;
  final raw = msg['data'];
  final Uint8List bytes;
  if (raw is String) {
    bytes = base64Decode(raw);
  } else if (raw is List) {
    bytes = Uint8List.fromList(raw.cast<int>());
  } else {
    throw const FormatException('Unknown image data format');
  }
  if (width <= 0 || height <= 0 || step < width * channels || bytes.length < step * height) {
    throw const FormatException('Invalid image dimensions or data');
  }
  final bgr = encoding == 'bgr8' || encoding == 'bgra8';
  final rgba = Uint8List(width * height * 4);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final src = y * step + x * channels;
      final dst = (y * width + x) * 4;
      rgba[dst] = bytes[src + (bgr ? 2 : 0)];
      rgba[dst + 1] = bytes[src + (channels == 1 ? 0 : 1)];
      rgba[dst + 2] = bytes[src + (channels == 1 || bgr ? 0 : 2)];
      rgba[dst + 3] = channels == 4 ? bytes[src + 3] : 255;
    }
  }
  return RgbaFrame(rgba, width, height);
}

/// sensor_msgs/CompressedImage has `format` + `data` (and no width/height/encoding).
bool isCompressedImage(Map msg) => msg['format'] is String && !msg.containsKey('encoding');

/// Decodes a CompressedImage (`format` like "rgb8; jpeg compressed bgr8" or "png") with the platform
/// codec. Depth images ("compressedDepth") are not viewable as colour and are rejected.
Future<ui.Image> decodeCompressedImage(Map msg) async {
  final format = (msg['format'] as String).toLowerCase();
  if (format.contains('compresseddepth')) throw const FormatException('Depth images cannot be shown');
  final raw = msg['data'];
  final Uint8List bytes = raw is String ? base64Decode(raw)
      : raw is List ? Uint8List.fromList(raw.cast<int>()) : throw const FormatException('Unknown image data format');
  if (bytes.isEmpty) throw const FormatException('Empty compressed image');
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    return (await codec.getNextFrame()).image;
  } finally {
    codec.dispose();
  }
}
