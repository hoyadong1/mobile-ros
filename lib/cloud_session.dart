import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'app_language.dart';
import 'l10n/generated/app_localizations.dart';
import 'relay_access.dart';
import 'relay_messages.dart';
import 'ros_connection.dart';

class CloudFailure implements Exception {
  const CloudFailure(this.text, {this.signInRequired = false});
  /// The message as written here or sent by the server (English for fixed messages).
  final String text;
  final bool signInRequired;
  /// [text] in the app's language.
  String get message => relayMessageIn(text, appStrings);
  @override
  String toString() => message;
}

abstract interface class SessionVault {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> clear();
}

class SecureSessionVault implements SessionVault {
  const SecureSessionVault(this.key);
  final String key;
  static const _storage = FlutterSecureStorage();
  @override
  Future<String?> read() => _storage.read(key: key);
  @override
  Future<void> write(String value) => _storage.write(key: key, value: value);
  @override
  Future<void> clear() => _storage.delete(key: key);
}

/// Browser sessions deliberately remain in memory. No refresh token is placed in localStorage.
class MemorySessionVault implements SessionVault {
  String? _value;
  @override
  Future<String?> read() async => _value;
  @override
  Future<void> write(String value) async { _value = value; }
  @override
  Future<void> clear() async { _value = null; }
}

class CloudRobot {
  const CloudRobot(this.id, this.name, this.online, {this.role = 'owner'});
  final String id, name;
  final bool online;
  /// 'owner', or for a robot someone shared: 'operator' (may drive) or 'viewer' (watch, and stop).
  final String role;
  bool get shared => role != 'owner';
  bool get viewOnly => role == 'viewer';
  factory CloudRobot.fromJson(Map<String, dynamic> value) => CloudRobot(
    value['id'] as String, value['name'] as String, value['online'] == true, role: '${value['role'] ?? 'owner'}');
}

/// Someone a robot is shared with (an opaque account id: the server keeps no one else's email).
typedef CloudMember = ({String user, String role});

class CloudUsage {
  const CloudUsage(this.usedBytes, this.limitBytes, this.available, {this.plan, this.maxActiveRobots});
  final int usedBytes, limitBytes;
  final bool available;
  final String? plan;
  final int? maxActiveRobots;
  bool get exhausted => !available || usedBytes >= limitBytes;
  String summaryIn(AppLocalizations s) {
    final (unit, divisor) = limitBytes >= 1000000000 ? ('GB', 1000000000)
      : limitBytes >= 1000000 ? ('MB', 1000000) : limitBytes >= 1000 ? ('KB', 1000) : ('bytes', 1);
    final limit = (limitBytes / divisor).toStringAsFixed(limitBytes % divisor == 0 ? 0 : 2);
    return s.remoteUsageSummary((usedBytes / divisor).toStringAsFixed(2), limit, unit);
  }
}

class CloudBillingConfig {
  const CloudBillingConfig({required this.enabled, required this.version, this.accountId,
    this.products = const {}, this.robotLimits = const {}, this.legacySubscriptions = false});
  final bool enabled, legacySubscriptions;
  final int version;
  final String? accountId;
  final Map<String, int> products;
  final Map<String, int> robotLimits;
}

/// The app caps manual speed before transmission; the relay independently validates it.
Map<String, dynamic> limitRemoteVelocity(Map<String, dynamic> message) {
  if (message['op'] != 'publish' || !RegExp(r'(^|/)cmd_vel$').hasMatch('${message['topic']}')) return message;
  final original = Map<String, dynamic>.from(message['msg'] as Map);
  final twist = Map<String, dynamic>.from((original['twist'] ?? original) as Map);
  for (final part in ['linear', 'angular']) {
    final vector = Map<String, dynamic>.from(twist[part] as Map);
    for (final axis in ['x', 'y', 'z']) {
      final n = vector[axis] ?? 0;
      final limit = part == 'linear' && axis == 'x' ? 0.25 : part == 'angular' && axis == 'z' ? 0.6 : 0.0;
      if (n is! num || !n.isFinite || (limit == 0 && n != 0)) throw StateError('Remote preview supports differential drive only.');
      vector[axis] = n.clamp(-limit, limit);
    }
    twist[part] = vector;
  }
  return {...message, 'msg': original.containsKey('twist') ? {...original, 'twist': twist} : twist};
}

/// Supabase owns passwords and authentication. AWS owns robot registration and access leases.
class CloudSession extends ChangeNotifier with WidgetsBindingObserver {
  CloudSession({String server = const String.fromEnvironment('CLOUD_SERVER', defaultValue: 'https://mobile-ros.com'),
      http.Client? client, SessionVault? vault})
      : base = Uri.parse(server), _http = client ?? http.Client(),
        _vault = vault ?? (kIsWeb ? MemorySessionVault() : SecureSessionVault('mobile_ros_account:$server')) {
    if (base.scheme != 'https' || base.host.isEmpty || base.userInfo.isNotEmpty || base.hasQuery ||
        base.hasFragment || (base.path.isNotEmpty && base.path != '/')) {
      throw const FormatException('Use the remote server HTTPS base URL.');
    }
    WidgetsBinding.instance.addObserver(this);
  }
  static final shared = CloudSession();
  final Uri base;
  final http.Client _http;
  final SessionVault _vault;
  bool _configured = false;
  String? _access, _refresh, email;
  DateTime _expires = DateTime(2000);
  Future<void>? _refreshing;
  final _connections = <CloudRosConnection>{};
  final _addresses = <String, String>{};
  int _generation = 0;
  bool _disposed = false;
  bool get signedIn => _access != null;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden || state == AppLifecycleState.detached) {
      for (final connection in _connections.toList()) {
        connection.lastError = relayMessageIn('Remote access paused. Reconnect when you return to the app.', appStrings);
        connection.close();
      }
    }
  }

  Future<CloudUsage> usage() async {
    final data = await _api('GET', '/api/usage');
    return CloudUsage(data['usedBytes'] as int, data['limitBytes'] as int, data['available'] == true,
      plan: data['plan'] as String?, maxActiveRobots: data['maxActiveRobots'] as int?);
  }
  Future<CloudBillingConfig> billingConfig() async {
    final version = _generation;
    final data = await _api('GET', '/api/billing');
    if (version != _generation || _disposed) throw const CloudFailure('Your account changed. Please try again.');
    if (data['enabled'] != true) return CloudBillingConfig(enabled: false, version: version);
    final account = data['accountId'];
    final products = data['products'];
    if (account is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(account) || products is! Map ||
        products.values.any((n) => n is! int || n <= 0)) {
      throw const CloudFailure('Remote purchase benefits are unavailable.');
    }
    return CloudBillingConfig(enabled: true, version: version, accountId: account,
      products: Map<String, int>.from(products), robotLimits: Map<String, int>.from(data['robotLimits'] as Map? ?? const {}),
      legacySubscriptions: data['legacySubscriptions'] == true);
  }
  Future<Map<String, dynamic>> verifyPlayPurchase(String product, String purchaseToken,
      {required int version, bool claimLegacy = false, bool refresh = false}) async {
    final token = await _token();
    if (version != _generation || _disposed) throw const CloudFailure('Your account changed. Please restore again.');
    final data = await _request('POST', base.resolve('/api/billing/verify'),
      headers: {'Authorization': 'Bearer $token'},
      body: {'product': product, 'token': purchaseToken, 'claimLegacy': claimLegacy, 'refresh': refresh});
    if (version != _generation || _disposed) throw const CloudFailure('Your account changed. Please restore again.');
    return data;
  }

  Future<Map<String, dynamic>> _request(String method, Uri url, {Map<String, String>? headers,
      Map<String, dynamic>? body}) async {
    try {
      final request = http.Request(method, url)..headers.addAll({'Content-Type': 'application/json', ...?headers});
      if (body != null) request.body = jsonEncode(body);
      request.followRedirects = false;
      final response = await _http.send(request).then(http.Response.fromStream).timeout(const Duration(seconds: 15));
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) throw const CloudFailure('The remote service returned an invalid response.');
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final code = decoded['error_code'] ?? decoded['code'];
        if (code == 'email_not_confirmed') throw const CloudFailure('Check your email to verify your account, then sign in.');
        if (code == 'invalid_credentials' || response.statusCode == 401 ||
            (url.path == '/api/auth/refresh' && response.statusCode == 400)) {
          throw const CloudFailure('Sign in again. Check your email and password.', signInRequired: true);
        }
        if (response.statusCode == 429) {
          if (url.host == base.host && decoded['error'] is String) throw CloudFailure(decoded['error']);
          throw const CloudFailure('Too many attempts. Please wait a minute and try again.');
        }
        if (url.host == base.host && decoded['error'] is String) throw CloudFailure(decoded['error']);
        throw const CloudFailure('Could not complete this request. Check your details and try again.');
      }
      return decoded;
    } on CloudFailure { rethrow; }
    catch (_) { throw const CloudFailure('Could not reach the remote service. Check your internet connection.'); }
  }

  Future<void> configure() async {
    if (_configured) return;
    final data = await _request('GET', base.resolve('/api/config'));
    if (data['available'] != true || data['auth'] is! Map) throw const CloudFailure('Remote access is being prepared. You can still connect locally.');
    if (data['auth']['provider'] != 'supabase') {
      throw const CloudFailure('Remote sign-in is unavailable. Please try again later.');
    }
    _configured = true;
  }
  Future<void> restore() async {
    await configure();
    final version = _generation;
    String? stored;
    try { stored = await _vault.read(); } catch (_) { return; }
    if (stored == null || version != _generation) return;
    _refresh = stored;
    try { await _refreshSession(); }
    on CloudFailure catch (error) {
      if (!error.signInRequired) rethrow;
      if (version == _generation) { _refresh = null; await _vault.clear(); }
    }
  }
  Future<void> _apply(Map<String, dynamic> data, int version) async {
    if (version != _generation || _disposed) throw const CloudFailure('Sign-in was canceled.');
    if (data['access_token'] is! String || data['refresh_token'] is! String) throw const CloudFailure('Could not start your session.');
    try { await _vault.write(data['refresh_token']); }
    catch (_) { throw const CloudFailure('Could not securely save your sign-in on this device.'); }
    if (version != _generation || _disposed) {
      await _vault.clear();
      throw const CloudFailure('Sign-in was canceled.');
    }
    _access = data['access_token']; _refresh = data['refresh_token'];
    email = data['user']?['email'];
    _expires = DateTime.now().add(Duration(seconds: (data['expires_in'] as num?)?.toInt() ?? 3600));
    notifyListeners();
  }
  Future<void> signIn(String email, String password) async {
    await configure();
    final version = ++_generation;
    final data = await _request('POST', base.resolve('/api/auth/signin'), body: {'email': email.trim(), 'password': password});
    await _apply(data, version);
  }
  Future<void> signUp(String email, String password) async {
    await configure();
    // Confirmation stays on. The person verifies the email, then signs in from this screen.
    await _request('POST', base.resolve('/api/auth/signup'), body: {'email': email.trim(), 'password': password});
  }
  /// Emails a reset link when the account exists; the answer is the same either way.
  Future<void> requestPasswordReset(String email) async {
    await configure();
    await _request('POST', base.resolve('/api/auth/recover'), body: {'email': email.trim()});
  }
  /// Sets a new password with the token of a reset link. Every device then signs in again.
  Future<void> setNewPassword(String resetToken, String password) async {
    await configure();
    await _request('POST', base.resolve('/api/account/password'),
        headers: {'Authorization': 'Bearer $resetToken'}, body: {'password': password});
  }
  /// Deletes the account and its robots (the password confirms it). True when the sign-in is gone
  /// at once; false when its removal is queued (the account is blocked either way).
  Future<bool> deleteAccount(String password) async {
    final data = await _api('DELETE', '/api/account', {'password': password});
    await _forgetLocally();
    return data['deleted'] == true;
  }
  Future<void> _refreshSession() async {
    if (_refreshing != null) return _refreshing;
    final version = _generation;
    final token = _refresh;
    if (token == null) throw const CloudFailure('Sign in to continue.');
    final work = () async {
      final data = await _request('POST', base.resolve('/api/auth/refresh'), body: {'refresh_token': token});
      await _apply(data, version);
    }();
    _refreshing = work;
    try { await work; } finally { _refreshing = null; }
  }
  Future<String> _token() async {
    // Renew before the next five-minute robot lease refresh can collide with JWT expiry.
    if (_access == null || _expires.difference(DateTime.now()) < const Duration(minutes: 7)) {
      await _refreshSession();
    }
    return _access!;
  }
  Future<Map<String, dynamic>> _api(String method, String path, [Map<String, dynamic>? body]) async =>
      _request(method, base.resolve(path), headers: {'Authorization': 'Bearer ${await _token()}'}, body: body);
  Future<List<CloudRobot>> robots() async {
    final data = await _api('GET', '/api/robots');
    return [for (final item in data['robots'] as List) CloudRobot.fromJson(Map<String, dynamic>.from(item))];
  }
  Future<void> claim(String code) async { await _api('POST', '/api/robots/claim', {'code': code.trim()}); }

  /// Sharing: a one-time code (7 days) for someone else's account, as 'operator' or 'viewer'. Owner only.
  Future<({String code, DateTime expires})> invite(CloudRobot robot, String role) async {
    final data = await _api('POST', '/api/robots/${robot.id}/invites', {'role': role});
    return (code: '${data['code']}', expires: DateTime.fromMillisecondsSinceEpoch((data['expiresAt'] as num).toInt()));
  }
  /// Adds the robot an invitation code is for to this account.
  Future<CloudRobot> join(String code) async {
    final data = await _api('POST', '/api/robots/join', {'code': code.trim()});
    return CloudRobot('${data['id']}', '${data['name']}', false, role: '${data['role']}');
  }
  Future<({List<CloudMember> members, int openInvites})> members(CloudRobot robot) async {
    final data = await _api('GET', '/api/robots/${robot.id}/members');
    return (
      members: [for (final m in (data['members'] as List? ?? const [])) (user: '${m['user']}', role: '${m['role']}')],
      openInvites: (data['invites'] as List? ?? const []).length,
    );
  }
  /// The owner removes [user]; with no [user], this account leaves a robot shared with it.
  Future<void> removeMember(CloudRobot robot, [String? user]) async {
    await _api('DELETE', '/api/robots/${robot.id}/members/${user ?? 'me'}');
    if (user == null) {
      for (final connection in _connections.toList()) {
        if (connection.robot.id == robot.id) connection.close();
      }
    }
  }
  /// The robot waiting for [code], shown before the person approves adding it.
  Future<({String name, bool online})> previewClaim(String code) async {
    final data = await _api('POST', '/api/robots/preview', {'code': code.trim()});
    return (name: '${data['name'] ?? 'Robot'}', online: data['online'] == true);
  }
  Future<void> remove(CloudRobot robot) async {
    await _api('DELETE', '/api/robots/${robot.id}');
    for (final connection in _connections.toList()) {
      if (connection.robot.id == robot.id) connection.close();
    }
    final address = _addresses.remove(robot.id);
    if (address != null) RelayAccess.setSessionToken(address, null);
  }
  Future<Map<String, dynamic>> ticket(CloudRobot robot) async {
    final data = await _api('POST', '/api/robots/${robot.id}/access');
    final address = '${data['address']}';
    final uri = Uri.tryParse(address);
    if (!RelayAccess.isRelay(address) || uri?.scheme != 'wss' || uri?.host != base.host ||
        (uri!.hasPort ? uri.port : 443) != base.port || uri.path != '/robots/${robot.id}') {
      throw const CloudFailure('Invalid robot address.');
    }
    RelayAccess.setSessionToken(address, data['token'] as String);
    _addresses[robot.id] = address;
    return data;
  }
  Future<CloudRosConnection> connect(CloudRobot robot) async {
    await ticket(robot);
    final connection = additionalConnection(robot);
    try { await connection.ready; return connection; }
    catch (_) { connection.close(); throw const CloudFailure('Could not connect. The robot may be offline or in use.'); }
  }
  CloudRosConnection additionalConnection(CloudRobot robot) {
    late final CloudRosConnection connection;
    connection = CloudRosConnection(this, robot, _addresses[robot.id]!, onClosed: () => _connections.remove(connection));
    _connections.add(connection);
    return connection;
  }
  /// Ends the session on this device: connections, robot tokens and the saved sign-in.
  Future<void> _forgetLocally() async {
    ++_generation;
    for (final connection in _connections.toList()) { connection.close(); }
    for (final address in _addresses.values) { RelayAccess.setSessionToken(address, null); }
    _addresses.clear(); _access = null; _refresh = null; email = null;
    await _vault.clear();
    if (!_disposed) notifyListeners();
  }
  Future<void> signOut() async {
    final oldAccess = _access;
    await _forgetLocally();
    if (oldAccess != null) {
      try { await _request('POST', base.resolve('/api/account/signout'), headers: {'Authorization': 'Bearer $oldAccess'}); } catch (_) {}
    }
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposed = true; ++_generation;
    for (final connection in _connections.toList()) { connection.close(); }
    for (final address in _addresses.values) { RelayAccess.setSessionToken(address, null); }
    _http.close();
    super.dispose();
  }
}

class CloudRosConnection extends RosBridgeConnection {
  CloudRosConnection(this.session, this.robot, String address, {required this.onClosed}) : super(address, '443') {
    _renewal = Timer.periodic(const Duration(minutes: 5), (_) => _renew());
    _expiry = Timer(const Duration(minutes: 30), () {
      lastError = relayMessageIn('Your 30-minute remote session ended. Reconnect from My robots.', appStrings);
      close();
    });
    messages.listen((message) {
      if (message['op'] == 'relay_challenge' && message['token'] is String) {
        _challenge = message['token'] as String;
        if (!_challengeReady.isCompleted) _challengeReady.complete();
      }
      if (message['op'] == 'relay_end') {
        lastError = relayMessageIn(message['msg'] is String ? message['msg'] as String : 'Your remote session ended.', appStrings);
        close();
      }
    }, onDone: _finish);
  }
  final CloudSession session;
  final CloudRobot robot;
  final VoidCallback onClosed;
  Timer? _renewal, _expiry;
  bool _renewing = false, _finished = false;
  String? _challenge;
  final _challengeReady = Completer<void>();
  @override
  Future<void> get ready async {
    await super.ready;
    await _challengeReady.future.timeout(timeout);
    if (isClosed) throw StateError(lastError ?? relayMessageIn('Remote connection closed.', appStrings));
  }
  Future<void> _renew() async {
    if (isClosed || _renewing) return;
    _renewing = true;
    try {
      final access = await session.ticket(robot);
      if (!isClosed) send({'op': 'relay_renew', 'token': access['token']});
    } catch (_) {
      lastError = relayMessageIn('Your remote session ended. Reconnect from My robots.', appStrings);
      close();
    } finally { _renewing = false; }
  }
  void _finish() {
    if (_finished) return;
    _finished = true; _renewal?.cancel(); _expiry?.cancel(); onClosed();
  }
  @override
  void send(Map<String, dynamic> message) {
    message = limitRemoteVelocity(message);
    if (message['op'] == 'publish' || message['op'] == 'send_action_goal') {
      if (_challenge == null) throw StateError('Remote control is preparing. Try again.');
      message = {...message, '_freshness': _challenge};
    }
    if (message['op'] == 'subscribe') {
      final image = RegExp('Image|PointCloud|image|camera|points').hasMatch('${message['type']} ${message['topic']}');
      final transform = RegExp(r'(^|/)tf(_static)?$').hasMatch('${message['topic']}') || '${message['type']}'.contains('TFMessage');
      final floor = transform ? 0 : compressesWell(message) ? 2000 : image ? 500 : 200;
      final requested = message['throttle_rate'];
      message = {...message, 'throttle_rate': requested is num && requested >= floor ? requested : floor, 'queue_length': 1};
    }
    super.send(message);
  }
  @override
  void close() {
    final reason = lastError;
    _finish(); super.close();
    if (reason != null) lastError = reason;
  }
}
