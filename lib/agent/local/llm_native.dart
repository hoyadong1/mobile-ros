/// Dart FFI bindings to libmobileros_llm (native/llm/mobileros_llm.c, llama.cpp), and the model file.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'local_backend.dart';

typedef _LoadC = Pointer<Void> Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>, Int32);
typedef _LoadD = Pointer<Void> Function(Pointer<Utf8>, int, int, Pointer<Utf8>, int);
typedef _GenC = Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Int32, Pointer<Utf8>, Int32);
typedef _GenD = int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Utf8>, int);
typedef _HC = Void Function(Pointer<Void>);
typedef _HD = void Function(Pointer<Void>);

class _Lib {
  _Lib(DynamicLibrary l)
      : load = l.lookupFunction<_LoadC, _LoadD>('ml_load'),
        generate = l.lookupFunction<_GenC, _GenD>('ml_generate'),
        cancel = l.lookupFunction<_HC, _HD>('ml_cancel'),
        free = l.lookupFunction<_HC, _HD>('ml_free');

  final _LoadD load;
  final _GenD generate;
  final _HD cancel, free;

  static _Lib? _instance;
  static String? loadError;

  /// The library for this platform, or null (then [loadError] says why). Each isolate opens its own.
  static _Lib? open() {
    if (_instance != null) return _instance;
    final candidates = Platform.isAndroid
        ? [if (_armDotProduct()) 'libmobileros_llm_dotprod.so', 'libmobileros_llm.so']
        : Platform.isWindows
            ? [
                ?Platform.environment['MOBILE_ROS_LLM_LIB'],
                'mobileros_llm.dll',
                'native/llm/prebuilt/windows-x64/mobileros_llm.dll', // flutter test from the repo
              ]
            : [?Platform.environment['MOBILE_ROS_LLM_LIB'], 'libmobileros_llm.so'];
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

/// Whether this ARM CPU has the dot-product instructions the faster library build uses.
bool _armDotProduct() {
  try {
    return RegExp(r'^Features\s*:.*\basimddp\b', multiLine: true)
        .hasMatch(File('/proc/cpuinfo').readAsStringSync());
  } catch (_) {
    return false;
  }
}

const _errors = {
  -1: 'bad arguments', -2: 'the chat template failed', -3: 'the prompt is too long', -4: 'the grammar is invalid',
  -5: 'the model failed while generating', -6: 'cancelled', -7: 'the answer is too long',
};

/// The on-device model (a GGUF file run by llama.cpp on the CPU). Loading and generating run on a
/// background isolate, so the UI keeps going; the model stays loaded until [dispose].
class NativeLlm implements LocalModel {
  NativeLlm(this.modelPath, {this.contextSize = 4096, this.threads = 4});

  final String modelPath;
  final int contextSize;
  final int threads;
  int _handle = 0;
  Future<int>? _loading;
  Future<void> _queue = Future.value();

  /// Whether the native library is present on this platform.
  static bool get available => _Lib.open() != null;
  static String? get loadError => _Lib.loadError;

  Future<int> _ensureLoaded() {
    if (_handle != 0) return Future.value(_handle);
    return _loading ??= () async {
      try {
        _handle = await _loadInBackground(modelPath, contextSize, threads);
        return _handle;
      } finally {
        _loading = null;
      }
    }();
  }

  // Static, so the closures sent to the background isolate capture only these arguments.
  static Future<int> _loadInBackground(String path, int ctx, int threads) =>
      Isolate.run(() => _load(path, ctx, threads));

  static Future<String> _generateInBackground(int h, String system, String user, String grammar, int maxTokens) =>
      Isolate.run(() => _generate(h, system, user, grammar, maxTokens));

  static int _load(String path, int ctx, int threads) {
    final lib = _Lib.open() ?? (throw StateError('On-device model library missing: ${_Lib.loadError}'));
    return using((arena) {
      final err = arena<Uint8>(256);
      err.value = 0;
      final h = lib.load(path.toNativeUtf8(allocator: arena), ctx, threads, err.cast<Utf8>(), 256);
      if (h == nullptr) throw StateError('Could not load the on-device model: ${err.cast<Utf8>().toDartString()}');
      return h.address;
    });
  }

  @override
  Future<String> generate({required String system, required String user, required String grammar,
      int maxTokens = 160}) {
    // One generation at a time on a handle.
    final run = _queue.then((_) async {
      final h = await _ensureLoaded();
      return _generateInBackground(h, system, user, grammar, maxTokens);
    });
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  static String _generate(int handle, String system, String user, String grammar, int maxTokens) {
    final lib = _Lib.open()!;
    return using((arena) {
      const cap = 16384;
      final out = arena<Uint8>(cap);
      final n = lib.generate(Pointer.fromAddress(handle), system.toNativeUtf8(allocator: arena),
          user.toNativeUtf8(allocator: arena), grammar.toNativeUtf8(allocator: arena), maxTokens,
          out.cast<Utf8>(), cap);
      if (n < 0) throw StateError('On-device model: ${_errors[n] ?? 'error $n'}');
      return out.cast<Utf8>().toDartString(length: n);
    });
  }

  @override
  void cancel() {
    if (_handle != 0) _Lib.open()?.cancel(Pointer.fromAddress(_handle));
  }

  Future<void> dispose() async {
    cancel();
    await _queue;
    final h = _handle;
    _handle = 0;
    if (h != 0) _Lib.open()?.free(Pointer.fromAddress(h));
  }
}

/// Where the on-device model file lives and how it gets there: downloaded once (about 1.3 GB) into the
/// app's support folder, not bundled with the app.
class LocalModelFile {
  static const fileName = 'Qwen3.5-2B-Q4_K_M.gguf';
  /// Qwen3.5-2B (Apache 2.0), 4-bit, as quantised by Unsloth.
  static final url = Uri.parse('https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/$fileName');
  static const sizeBytes = 1281000000;

  /// An explicit file (MOBILE_ROS_LLM_MODEL, for desktop and tests) or the downloaded one.
  static Future<String?> path() async {
    final env = Platform.environment['MOBILE_ROS_LLM_MODEL'];
    if (env != null && env.isNotEmpty) return env;
    try {
      final sep = Platform.pathSeparator;
      return '${(await getApplicationSupportDirectory()).path}${sep}models$sep$fileName';
    } catch (_) {
      return null;
    }
  }

  static Future<bool> exists() async {
    final p = await path();
    return p != null && File(p).existsSync();
  }

  /// Downloads the model next to its final place and moves it there when complete.
  static Future<void> download({void Function(int received, int total)? onProgress, http.Client? client}) async {
    final p = await path() ?? (throw StateError('No folder for the model on this device.'));
    final part = File('$p.part');
    await part.parent.create(recursive: true);
    final c = client ?? http.Client();
    try {
      final response = await c.send(http.Request('GET', url));
      if (response.statusCode != 200) throw StateError('Model download failed: HTTP ${response.statusCode}');
      final total = response.contentLength ?? sizeBytes;
      final sink = part.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.close();
      }
      if (received < total) throw StateError('Model download was cut off.');
      await part.rename(p);
    } finally {
      if (client == null) c.close();
    }
  }

  static Future<void> delete() async {
    final p = await path();
    if (p != null && File(p).existsSync()) await File(p).delete();
  }
}
