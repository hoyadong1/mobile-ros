/// The Zenoh connection for this platform: the zenoh-pico implementation where `dart:ffi` exists
/// (Android, desktop, tests), a stand-in that reports "not supported" on the web.
/// App code imports this file, so the web build compiles.
library;

export 'zenoh_connection.dart' if (dart.library.js_interop) 'zenoh_unsupported.dart';
