import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

/// The code in a robot's approval link: https://mobile-ros.com/link/XXXX-XXXX (QR codes) or the web
/// app's /app/#/link?code=XXXX-XXXX. Null for anything else.
String? robotCodeFromLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || uri.scheme != 'https' || uri.host != 'mobile-ros.com') return null;
  final segments = uri.pathSegments;
  if (segments.length == 2 && segments[0] == 'link') return segments[1];
  if (uri.path == '/app/' && uri.fragment.startsWith('/link?')) {
    return Uri.tryParse(uri.fragment)?.queryParameters['code'];
  }
  return null;
}

/// Approval links that open the Android app (App Links, verified by the server's assetlinks.json):
/// the first one that started the app and any that arrive while it runs.
class AppLinks {
  static const _channel = MethodChannel('mobile_ros/links');
  static final _codes = StreamController<String>.broadcast();
  static String? _pending;
  static bool _started = false;

  /// Codes from links that arrive while the app runs.
  static Stream<String> get codes => _codes.stream;

  /// Once, at start-up (Android only; elsewhere nothing arrives).
  static Future<void> start() async {
    if (_started || kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'link') return;
      final code = robotCodeFromLink('${call.arguments}');
      if (code != null) _codes.add(code);
    });
    try {
      final first = await _channel.invokeMethod<String>('initialLink');
      if (first != null) _pending = robotCodeFromLink(first);
    } on PlatformException {
      // No link.
    } on MissingPluginException {
      // Not the Android app.
    }
  }

  /// The code of the link that started the app, once.
  static String? takePending() {
    final code = _pending;
    _pending = null;
    return code;
  }
}
