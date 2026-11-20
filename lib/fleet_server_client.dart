import 'dart:convert';
import 'package:http/http.dart' as http;

/// HTTP client for an on-site fleet server. The token stays in memory for this screen only.
class FleetServerClient {
  FleetServerClient(String address, this.token, {http.Client? client,
      this.requestTimeout = const Duration(seconds: 10)})
      : base = Uri.parse(address.endsWith('/') ? address : '$address/'),
        _http = client ?? http.Client(), _ownsClient = client == null {
    if ((base.scheme != 'http' && base.scheme != 'https') || base.host.isEmpty) {
      throw const FormatException('Enter a full HTTP(S) server URL.');
    }
    if (base.userInfo.isNotEmpty || base.query.isNotEmpty || base.fragment.isNotEmpty) {
      throw const FormatException('Enter a server URL without credentials or query parameters.');
    }
    if (token.isEmpty) throw const FormatException('Enter the operator token.');
  }

  final Uri base;
  final String token;
  final http.Client _http;
  final bool _ownsClient;
  final Duration requestTimeout;

  Uri _url(String path) => base.resolve(path);
  Map<String, String> get _headers => {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'};

  Future<Map<String, dynamic>> _decode(http.Response response) async {
    final data = jsonDecode(response.body);
    if (data is! Map) throw const FormatException('Invalid fleet server response.');
    final result = Map<String, dynamic>.from(data);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('${result['error'] ?? 'Server error'} (${response.statusCode})');
    }
    return result;
  }

  Future<Map<String, dynamic>> state() async => _decode(await _http.get(_url('api/state'), headers: _headers).timeout(requestTimeout));
  Future<Map<String, dynamic>> map() async => _decode(await _http.get(_url('api/map'), headers: _headers).timeout(requestTimeout));

  Future<Map<String, dynamic>> createTask(String robot, String destination) async =>
      _decode(await _http.post(_url('api/tasks'), headers: _headers,
        body: jsonEncode({'robot': robot, 'destination': destination})).timeout(requestTimeout));

  Future<Map<String, dynamic>> cancelTask(String id) async =>
      _decode(await _http.post(_url('api/tasks/$id/cancel'), headers: _headers).timeout(requestTimeout));

  Future<void> stopAll() async {
    await _decode(await _http.post(_url('api/stop_all'), headers: _headers).timeout(requestTimeout));
  }

  void close() { if (_ownsClient) _http.close(); }
}
