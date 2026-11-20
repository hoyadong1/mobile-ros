/// Stand-in for `zenoh_connection.dart` in the web build: the Zenoh connection runs zenoh-pico through
/// FFI and raw TCP, which a browser cannot do. Import `zenoh.dart`, never this file.
library;

import '../ros_connection.dart';

const _unsupported = 'Zenoh needs the Android or desktop app. In a browser, connect through rosbridge.';

/// Whether this build can open a Zenoh connection at all.
const zenohSupported = false;

class ZenohRosSession {
  ZenohRosSession._();

  static Future<ZenohRosSession> open({required String router, int domain = 0}) =>
      Future.error(UnsupportedError(_unsupported));

  ZenohRosConnection connect({bool ownsSession = false}) => throw UnsupportedError(_unsupported);
  void close() {}
}

/// Never instantiated on this platform; present so the type exists for the app code.
abstract class ZenohRosConnection implements RosConnection {}
