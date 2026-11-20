import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Splits a byte stream of concatenated JPEGs (an MJPEG `multipart/x-mixed-replace` body, as sent by
/// ROS web_video_server) into complete JPEG frames by their SOI (FF D8 FF) and EOI (FF D9) markers.
/// Boundaries and part headers between frames are skipped, so any server's boundary string works.
class JpegFrameSplitter {
  JpegFrameSplitter({this.maxBuffer = 8 * 1024 * 1024});

  final int maxBuffer;

  /// Bytes not yet emitted, in `_buf[0, _len)`. Grows by doubling, so appending is amortised O(1).
  Uint8List _buf = Uint8List(64 * 1024);
  int _len = 0;

  /// While a frame is incomplete it sits at index 0; this is where the end-marker search resumes, so
  /// each byte is scanned once however many chunks the frame arrives in.
  int _resumeEnd = 0;

  /// Feeds [chunk] and returns every frame it completed (usually 0 or 1).
  List<Uint8List> add(List<int> chunk) {
    _append(chunk);
    final frames = <Uint8List>[];
    var from = 0;
    while (true) {
      final data = Uint8List.sublistView(_buf, 0, _len);
      final start = _indexOf(data, const [0xFF, 0xD8, 0xFF], from);
      if (start < 0) {
        // Keep a 2-byte tail in case a marker was split across chunks.
        _compact(math.max(from, _len - 2));
        _resumeEnd = 0;
        break;
      }
      final end = _indexOf(data, const [0xFF, 0xD9], start == 0 ? math.max(3, _resumeEnd) : start + 3);
      if (end < 0) {
        _compact(start); // incomplete frame: move it to the front and wait for more bytes
        _resumeEnd = math.max(3, _len - 1); // the 2-byte end marker may straddle the next chunk
        break;
      }
      frames.add(Uint8List.fromList(Uint8List.sublistView(data, start, end + 2)));
      from = end + 2;
      _resumeEnd = 0;
    }
    if (_len > maxBuffer) { // corrupt stream: start over
      _len = 0;
      _resumeEnd = 0;
    }
    return frames;
  }

  void _append(List<int> chunk) {
    final needed = _len + chunk.length;
    if (needed > _buf.length) {
      var size = _buf.length;
      while (size < needed) {
        size *= 2;
      }
      _buf = Uint8List(size)..setRange(0, _len, _buf);
    }
    _buf.setRange(_len, needed, chunk);
    _len = needed;
  }

  /// Drops the first [count] bytes.
  void _compact(int count) {
    if (count <= 0) return;
    if (count >= _len) {
      _len = 0;
      return;
    }
    _buf.setRange(0, _len - count, _buf, count);
    _len -= count;
  }

  static int _indexOf(Uint8List data, List<int> pattern, int from) {
    for (var i = from; i <= data.length - pattern.length; i++) {
      var match = true;
      for (var j = 0; j < pattern.length; j++) {
        if (data[i + j] != pattern[j]) { match = false; break; }
      }
      if (match) return i;
    }
    return -1;
  }
}

/// MJPEG-over-HTTP client that reconnects with backoff (1 s, 2 s, ... 10 s) until [stop].
class MjpegStream {
  MjpegStream(this.url, {required this.onFrame, required this.onError, HttpClient? client})
      : _client = client ?? HttpClient();

  final Uri url;
  final void Function(Uint8List jpeg) onFrame;
  final void Function(Object error) onError;
  final HttpClient _client;
  StreamSubscription<List<int>>? _body;
  Timer? _retry;
  bool _stopped = false;
  int _failures = 0;

  void start() => _connect();

  Future<void> _connect() async {
    if (_stopped) return;
    try {
      final request = await _client.getUrl(url).timeout(const Duration(seconds: 8));
      final response = await request.close().timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode} from $url');
      }
      if (_stopped) { await response.drain<void>(); return; }
      final splitter = JpegFrameSplitter();
      _body = response.listen((chunk) {
        for (final frame in splitter.add(chunk)) {
          _failures = 0;
          onFrame(frame);
        }
      }, onError: _fail, onDone: () => _fail(const HttpException('MJPEG stream ended')), cancelOnError: true);
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object error) {
    if (_stopped) return;
    onError(error);
    _body?.cancel();
    _body = null;
    final delay = Duration(seconds: (1 << _failures.clamp(0, 3)).clamp(1, 10));
    _failures++;
    _retry = Timer(delay, _connect);
  }

  void stop() {
    _stopped = true;
    _retry?.cancel();
    _body?.cancel();
    _client.close(force: true);
  }
}

/// web_video_server's MJPEG URL for [topic] on [host] (default port 8080). The topic's slashes stay
/// literal: web_video_server does not percent-decode the query, so "%2Fcamera%2Fimage_raw" is rejected
/// as an invalid topic name (verified against web_video_server 3.1.0). "/" is legal in a URI query.
String webVideoServerUrl(String host, String topic, {int port = 8080, int quality = 80}) =>
    'http://${host.contains(':') ? '[$host]' : host}:$port/stream?topic=$topic&type=mjpeg&quality=$quality';
