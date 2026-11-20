/// The direct ROS 2 connection for this platform: the Cyclone DDS implementation where `dart:ffi`
/// exists (Android, desktop, tests), a stand-in that reports "not supported" on the web.
/// App code imports this file instead of `direct_connection.dart`, so the web build compiles.
library;

// The real implementation is the default (so the analyzer and tests see it); web builds swap in the
// stand-in.
export 'direct_connection.dart' if (dart.library.js_interop) 'direct_unsupported.dart';
