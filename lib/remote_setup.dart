import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_language.dart';
import 'cloud_session.dart';
import 'relay_messages.dart';

/// Turning on remote access for a robot the phone reaches nearby, from the app alone: it signs in to
/// the robot computer over SSH once (password or private key), installs the Mobile ROS agent as a service
/// that starts at boot (robot_side/install_agent.sh) and registers the robot to the signed-in account.
/// The password and key go only to SSH and to sudo's standard input; they are never stored, logged or
/// put on a command line.
class RemoteSetupFailure implements Exception {
  const RemoteSetupFailure(this.text);
  /// The fixed English message, or an installer's own failure line.
  final String text;
  /// [text] in the app's language.
  String get message => relayMessageIn(text, appStrings);
  @override
  String toString() => message;
}

/// What the setup needs from the robot computer (SSH in the app; a fake in tests).
abstract interface class RobotShell {
  Future<void> upload(String path, Uint8List data);
  /// Runs [command]; [stdin] is written first (then closed). Yields output lines (stdout and stderr).
  Stream<String> run(String command, {String? stdin});
  Future<void> close();
}

/// The robot computer over SSH (password or private-key sign-in, host key checked by [verifyHostKey]).
class SshRobotShell implements RobotShell {
  SshRobotShell._(this._client);
  final SSHClient _client;
  SftpClient? _sftp;

  static Future<SshRobotShell> connect({required String host, int port = 22, required String user,
      String password = '', String? privateKey, String? passphrase,
      required Future<bool> Function(String fingerprint) verifyHostKey}) async {
    List<SSHKeyPair>? identities;
    if (privateKey != null && privateKey.trim().isNotEmpty) {
      try {
        identities = SSHKeyPair.fromPem(privateKey.trim(), passphrase == null || passphrase.isEmpty ? null : passphrase);
      } catch (_) {
        throw const RemoteSetupFailure('Could not read the private key. Paste the whole key '
            '(-----BEGIN ... PRIVATE KEY----- to the END line) and its passphrase if it has one.');
      }
    }
    final SSHSocket socket;
    try {
      socket = await SSHSocket.connect(host, port, timeout: const Duration(seconds: 10));
    } catch (_) {
      throw const RemoteSetupFailure('Could not reach the robot computer over SSH. Check that SSH is on (port 22).');
    }
    var hostKeyRejected = false;
    final client = SSHClient(socket, username: user, identities: identities,
      onPasswordRequest: identities == null ? () => password : null,
      onVerifyHostKey: (type, fingerprint) async {
        final ok = await verifyHostKey(utf8.decode(fingerprint));
        hostKeyRejected = !ok;
        return ok;
      });
    try {
      await client.authenticated.timeout(const Duration(seconds: 20));
    } catch (_) {
      client.close();
      throw RemoteSetupFailure(hostKeyRejected
          ? 'The robot computer was not confirmed. Nothing was installed.'
          : identities != null
              ? 'Could not sign in with this key. Check the user name and that the key is allowed on the robot computer.'
              : 'Could not sign in to the robot computer. Check the user name and password.');
    }
    return SshRobotShell._(client);
  }

  @override
  Future<void> upload(String path, Uint8List data) async {
    final sftp = _sftp ??= await _client.sftp();
    final file = await sftp.open(path, mode: SftpFileOpenMode.create | SftpFileOpenMode.truncate | SftpFileOpenMode.write);
    try { await file.writeBytes(data); } finally { await file.close(); }
  }

  @override
  Stream<String> run(String command, {String? stdin}) async* {
    final session = await _client.execute(command);
    if (stdin != null) session.stdin.add(Uint8List.fromList(utf8.encode(stdin)));
    await session.stdin.close();
    final lines = StreamController<String>();
    var open = 2;
    void listen(Stream<Uint8List> stream) => stream.cast<List<int>>().transform(utf8.decoder)
        .transform(const LineSplitter()).listen(lines.add, onDone: () { if (--open == 0) lines.close(); });
    listen(session.stdout);
    listen(session.stderr);
    yield* lines.stream;
    await session.done;
  }

  @override
  Future<void> close() async {
    await _sftp?.close();
    _client.close();
  }
}

/// Quotes [value] for a POSIX shell.
String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// The setup's outcome: a robot registered just now, or one set up before.
class RemoteSetupResult {
  const RemoteSetupResult({this.robotId, required this.alreadySetUp});
  final String? robotId;
  final bool alreadySetUp;
}

class RemoteSetup {
  static const files = ['install_agent.sh', 'register_robot.py', 'mobile_ros_agent.py'];

  /// Installs and registers. [onStep] gets each progress line the robot reports.
  /// [claim] registers the one-time code to the signed-in account (CloudSession.claim).
  static Future<RemoteSetupResult> install(RobotShell shell, {required String relay, required String name,
      required String user, String? sudoPassword, bool rosbridgeService = true, bool reregister = false,
      required Future<void> Function(String code) claim, void Function(String step)? onStep,
      Future<Uint8List> Function(String file)? read}) async {
    read ??= (file) async => (await rootBundle.load('robot_side/$file')).buffer.asUint8List();
    final dir = '/tmp/mobile-ros-setup-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
    onStep?.call('Copying the setup files');
    await shell.run('umask 077 && mkdir ${shellQuote(dir)}').drain<void>();
    for (final file in files) {
      await shell.upload('$dir/$file', await read(file));
    }
    // Without a password (key sign-in on a computer with passwordless sudo) sudo must not wait for one.
    final withPassword = sudoPassword != null && sudoPassword.isNotEmpty;
    final command = [
      'sudo', if (withPassword) ...['-S', '-p', "''"] else '-n', 'bash', shellQuote('$dir/install_agent.sh'),
      '--relay', shellQuote(relay), '--name', shellQuote(name), '--user', shellQuote(user),
      '--rosbridge-service', rosbridgeService ? 'yes' : 'no',
      if (reregister) '--reregister',
    ].join(' ');
    String? result, failure;
    var sudoRefused = false, sudoNeedsPassword = false;
    try {
      // The password reaches sudo on standard input only; the files are removed whatever happens.
      await for (final line in shell.run('$command; status=\$?; rm -rf ${shellQuote(dir)}; exit \$status',
          stdin: withPassword ? '$sudoPassword\n' : null)) {
        if (line.startsWith('STEP ')) onStep?.call(line.substring(5));
        if (line.startsWith('FAIL ')) failure = line.substring(5);
        if (line.startsWith('RESULT ')) result = line.substring(7);
        if (RegExp(r'incorrect password|Sorry, try again|not in the sudoers|may not run sudo').hasMatch(line)) sudoRefused = true;
        if (!withPassword && line.contains('a password is required')) sudoNeedsPassword = true;
      }
    } catch (_) {
      throw const RemoteSetupFailure('The connection to the robot computer was lost during setup.');
    }
    if (sudoNeedsPassword) throw RemoteSetupFailure('sudo asks $user for a password. Enter it under "sudo password".');
    if (sudoRefused) throw RemoteSetupFailure('$user cannot use sudo with this password. Use an administrator account.');
    if (failure != null) throw RemoteSetupFailure(failure);
    if (result == null) throw const RemoteSetupFailure('Setup did not finish. Try again.');
    final data = jsonDecode(result) as Map<String, dynamic>;
    if (data['status'] == 'already') return const RemoteSetupResult(alreadySetUp: true);
    final code = data['code'];
    if (code is! String || !RegExp(r'^[A-HJKMNP-TV-Z2-9]{4}-[A-HJKMNP-TV-Z2-9]{4}$').hasMatch(code)) {
      throw const RemoteSetupFailure('The robot returned an invalid registration.');
    }
    onStep?.call('Adding the robot to your account');
    await claim(code);
    return RemoteSetupResult(robotId: data['id'] as String?, alreadySetUp: false);
  }
}

/// Remembers each robot computer's SSH host key the first time it is confirmed; a different key later
/// is refused (someone else may be answering at that address).
class KnownRobotHosts {
  static const _key = 'robot_ssh_host_keys';

  static Future<String?> fingerprintFor(String host) async {
    try {
      final map = jsonDecode((await SharedPreferences.getInstance()).getString(_key) ?? '{}');
      return map is Map ? map[host] as String? : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> remember(String host, String fingerprint) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final map = jsonDecode(prefs.getString(_key) ?? '{}');
      await prefs.setString(_key, jsonEncode({if (map is Map) ...map, host: fingerprint}));
    } catch (_) { /* asked again next time */ }
  }
}

/// The relay base address (HTTPS) of the account server the app uses.
String relayBase(CloudSession session) => session.base.origin;
