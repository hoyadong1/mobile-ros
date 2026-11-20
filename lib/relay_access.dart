import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Reaching a robot through the Mobile ROS relay: its address is
/// `wss://<relay>/robots/<robot id>` and the app presents a user token the robot's owner made.
/// Step-1 prototype: tokens are kept in the app's private storage per address; with accounts (step 2)
/// they become short-lived login tokens in secure storage.
class RelayAccess {
  static final _tokens = <String, String>{};
  static final _sessionTokens = <String, String>{};
  static const _key = 'relay_tokens';

  /// A relay robot address (`ws://` only for a relay on this computer or network while testing).
  static bool isRelay(String address) {
    final uri = Uri.tryParse(address.trim());
    // Uri normalises an explicit :0 away for ws/wss; validate the original port as well.
    final authority = address.trim().split('://').last.split(RegExp(r'[/?#]')).first;
    final rawPort = RegExp(r':([0-9]+)$').firstMatch(authority)?.group(1);
    final number = rawPort == null ? null : int.tryParse(rawPort);
    return uri != null && {'ws', 'wss'}.contains(uri.scheme) &&
        uri.host.isNotEmpty && uri.userInfo.isEmpty && !uri.hasQuery && !uri.hasFragment &&
        (rawPort == null || (number != null && number >= 1 && number <= 65535)) &&
        (!uri.hasPort || (uri.port >= 1 && uri.port <= 65535)) &&
        RegExp(r'^/robots/[A-Za-z0-9_-]{3,64}/?$').hasMatch(uri.path);
  }

  static String _id(String address) {
    final uri = Uri.parse(address.trim());
    return uri.replace(host: uri.host.toLowerCase(),
        path: uri.path.replaceAll(RegExp(r'/$'), '')).toString();
  }

  static bool validToken(String token) => RegExp(r'^[A-Za-z0-9_-]{1,256}$').hasMatch(token.trim());

  static Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final map = raw == null ? const {} : jsonDecode(raw);
      _tokens..clear()..addAll({if (map is Map) for (final e in map.entries)
        if (e.key is String && e.value is String && isRelay(e.key) && validToken(e.value))
          _id(e.key): e.value});
    } catch (_) {
      _tokens.clear();
    }
  }

  static String? tokenFor(String address) => _sessionTokens[_id(address)] ?? _tokens[_id(address)];

  /// Account access tickets live only in memory, never in the legacy preferences file.
  static void setSessionToken(String address, String? token) {
    if (token == null) { _sessionTokens.remove(_id(address)); return; }
    if (!isRelay(address) || !validToken(token)) throw const FormatException('Invalid remote access ticket.');
    _sessionTokens[_id(address)] = token;
  }

  static Future<void> save(String address, String token) async {
    final t = token.trim();
    if (!isRelay(address) || (t.isNotEmpty && !validToken(t))) {
      throw const FormatException('Enter a valid relay address and access token.');
    }
    if (t.isEmpty) {
      _tokens.remove(_id(address));
    } else {
      _tokens[_id(address)] = t;
    }
    try {
      await (await SharedPreferences.getInstance()).setString(_key, jsonEncode(_tokens));
    } catch (_) { /* kept for this session */ }
  }

  /// The WebSocket subprotocol that carries the token (works on every platform, unlike headers).
  static List<String>? protocolsFor(Uri uri) {
    final token = tokenFor(uri.toString());
    return token == null ? null : ['bearer.$token'];
  }
}
