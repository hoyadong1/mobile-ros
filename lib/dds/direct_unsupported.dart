/// Stand-in for `direct_connection.dart` on platforms without `dart:ffi` (the web build). The direct
/// ROS 2 connection runs Cyclone DDS through FFI and UDP multicast, which a browser cannot do, so
/// here it only reports that; rosbridge works everywhere. Import `direct.dart`, never this file.
library;

import 'dart:convert';
import 'package:flutter/services.dart';
import '../ros_connection.dart';
import 'ros_interfaces.dart';

const _unsupported = 'Direct ROS 2 needs the Android app. In a browser, connect through rosbridge.';

/// Whether this build can open a direct ROS 2 connection at all.
const directRosSupported = false;

/// Never thrown here; declared so app code compiles the same on every platform.
class DirectTopicsUnreachable implements Exception {
  const DirectTopicsUnreachable(this.participants);
  final int participants;
}

class DirectRosSession {
  DirectRosSession._();

  static Future<DirectRosSession> open({required String robot, required int domain,
      RosInterfaces? interfaces, Duration discoveryTimeout = const Duration(seconds: 6)}) =>
      Future.error(UnsupportedError(_unsupported));

  RosInterfaces get interfaces => throw UnsupportedError(_unsupported);
  List<String> get unknownInterfaces => const [];
  DirectRosConnection connect({bool ownsSession = false}) => throw UnsupportedError(_unsupported);
  void close() {}
}

/// Never instantiated on this platform; present so `connection is DirectRosConnection` compiles.
abstract class DirectRosConnection implements RosConnection {
  DirectRosSession get session;
}

Future<RosInterfaces> loadBundledInterfaces() async {
  final text = await rootBundle.loadString('assets/ros2_interfaces.json');
  return RosInterfaces(Map<String, String>.from(jsonDecode(text) as Map));
}
