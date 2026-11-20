/// The on-device model for this platform: llama.cpp through FFI where `dart:ffi` exists (Android,
/// desktop, tests), a stand-in that reports "not available" on the web. App code imports this file.
library;

export 'llm_native.dart' if (dart.library.js_interop) 'llm_unsupported.dart';
