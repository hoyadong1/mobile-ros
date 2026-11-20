import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/app_links.dart';
import 'package:ros_tester/link_robot_page.dart';
import 'package:ros_tester/remote_setup.dart';
import 'package:ros_tester/remote_setup_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_cloud_session.dart';

/// The robot computer, as the setup sees it: files written, commands run, what it answers.
class FakeShell implements RobotShell {
  FakeShell(this.answer);
  final List<String> Function(String command, String? stdin) answer;
  final uploads = <String, String>{};
  final commands = <(String, String?)>[];
  bool closed = false;
  @override
  Future<void> upload(String path, Uint8List data) async => uploads[path] = utf8.decode(data);
  @override
  Stream<String> run(String command, {String? stdin}) async* {
    commands.add((command, stdin));
    for (final line in answer(command, stdin)) {
      yield line;
    }
  }
  @override
  Future<void> close() async => closed = true;
}

Future<Uint8List> readFake(String file) async => Uint8List.fromList(utf8.encode('content of $file'));

/// The setup page shows a spinner while it works, so it never settles; pump until [finder] shows.
Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(finder, findsWidgets);
}

const registered = 'RESULT {"id":"r-1","code":"K7QM-4XTD"}';

void main() {
  test('shell quoting keeps names with quotes and spaces as one argument', () {
    expect(shellQuote("Bob's robot"), r"'Bob'\''s robot'");
    expect(shellQuote(r'$(rm -rf /)'), r"'$(rm -rf /)'");
  });

  test('only Mobile ROS approval links give a code', () {
    expect(robotCodeFromLink('https://mobile-ros.com/link/K7QM-4XTD'), 'K7QM-4XTD');
    expect(robotCodeFromLink('https://mobile-ros.com/app/#/link?code=K7QM-4XTD'), 'K7QM-4XTD');
    expect(robotCodeFromLink('https://evil.example/link/K7QM-4XTD'), isNull);
    expect(robotCodeFromLink('http://mobile-ros.com/link/K7QM-4XTD'), isNull);
    expect(robotCodeFromLink('K7QM-4XTD'), isNull);
  });

  test('short codes are read the way people type them', () {
    expect(normalizeRobotCode('k7qm 4xtd'), 'K7QM-4XTD');
    expect(normalizeRobotCode('K7QM4XTD'), 'K7QM-4XTD');
    expect(normalizeRobotCode('K7QM-4XT1'), isNull, reason: '1 is never used (looks like I)');
    expect(normalizeRobotCode('K7QM-4XT'), isNull);
  });

  test('the setup uploads the robot files, passes the password only to sudo and registers the code', () async {
    final shell = FakeShell((command, stdin) => command.contains('install_agent.sh')
        ? ['STEP Installing the agent', 'STEP Registering with Mobile ROS', registered]
        : []);
    final claimed = <String>[], steps = <String>[];
    final result = await RemoteSetup.install(shell, relay: 'https://mobile-ros.com', name: "Bob's robot", user: 'ubuntu',
        sudoPassword: 'p@ss word', claim: (code) async => claimed.add(code), onStep: steps.add, read: readFake);
    expect(result.alreadySetUp, isFalse);
    expect(claimed, ['K7QM-4XTD']);
    expect(steps, ['Copying the setup files', 'Installing the agent', 'Registering with Mobile ROS', 'Adding the robot to your account']);
    final dir = shell.uploads.keys.first.substring(0, shell.uploads.keys.first.lastIndexOf('/'));
    expect(dir, startsWith('/tmp/mobile-ros-setup-'));
    expect(shell.uploads.keys.map((p) => p.split('/').last).toSet(), RemoteSetup.files.toSet());
    expect(shell.commands.first.$1, contains('umask 077 && mkdir'), reason: 'a private folder');
    final (install, stdin) = shell.commands.last;
    expect(install, contains("sudo -S -p '' bash"));
    expect(install, contains(r"--name 'Bob'\''s robot'"));
    expect(install, contains("--relay 'https://mobile-ros.com'"));
    expect(install, contains('--rosbridge-service yes'));
    expect(install, contains('rm -rf'), reason: 'the files are removed afterwards');
    expect(install.contains('p@ss'), isFalse, reason: 'never on a command line');
    expect(stdin, 'p@ss word\n', reason: 'only on sudo standard input');
  });

  test('with a key and no sudo password, sudo is told never to wait for one', () async {
    final shell = FakeShell((c, _) => c.contains('install_agent.sh') ? [registered] : []);
    await RemoteSetup.install(shell, relay: 'https://mobile-ros.com', name: 'R', user: 'ubuntu',
        claim: (_) async {}, read: readFake);
    final (install, stdin) = shell.commands.last;
    expect(install, contains('sudo -n bash'));
    expect(stdin, isNull);
  });

  test('wrong sudo password, a failure on the robot and an earlier setup are told apart', () async {
    Future<Object?> outcome(List<String> lines, {String? sudo = 'x'}) async {
      try {
        return await RemoteSetup.install(FakeShell((c, _) => c.contains('install_agent.sh') ? lines : []),
            relay: 'https://mobile-ros.com', name: 'R', user: 'ubuntu', sudoPassword: sudo, claim: (_) async => fail('no claim'), read: readFake);
      } on RemoteSetupFailure catch (error) {
        return error.message;
      }
    }
    expect(await outcome(['Sorry, try again.', 'sudo: 1 incorrect password attempt']), contains('cannot use sudo'));
    expect(await outcome(['sudo: a password is required'], sudo: null), contains('sudo password'));
    expect(await outcome(['STEP Installing the agent', 'FAIL Could not install tornado (internet needed).']), contains('internet'));
    expect(await outcome(['STEP x']), contains('did not finish'));
    expect(((await outcome(['RESULT {"status":"already"}'])) as RemoteSetupResult).alreadySetUp, isTrue);
    expect(await outcome(['RESULT {"id":"r-1","code":"ABCDEF0123456789ABCD"}']), contains('invalid registration'));
  });

  group('setup page', () {
    late FakeCloudSession session;
    late String fingerprint;
    late int installs;
    late List<(String password, String? key, String? passphrase, String? sudoStdin)> signIns;
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      session = FakeCloudSession(signedIn: true);
      fingerprint = 'SHA256:first-key';
      installs = 0;
      signIns = [];
    });
    tearDown(() => session.dispose());

    Future<RobotShell> connect({required String host, required int port, required String user, String password = '',
        String? privateKey, String? passphrase, required Future<bool> Function(String fingerprint) verifyHostKey}) async {
      if (!await verifyHostKey(fingerprint)) throw const RemoteSetupFailure('The robot computer was not confirmed. Nothing was installed.');
      return FakeShell((command, stdin) {
        if (!command.contains('install_agent.sh')) return [];
        installs++;
        signIns.add((password, privateKey, passphrase, stdin));
        return ['STEP Installing the agent', registered];
      });
    }

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(home: RemoteSetupPage(host: '192.168.1.20', name: 'TurtleBot3', session: session, connect: connect)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('remote-user')), 'ubuntu');
    }

    Future<void> start(WidgetTester tester) async {
      await tester.ensureVisible(find.byKey(const Key('remote-setup')));
      await tester.tap(find.byKey(const Key('remote-setup')));
    }

    testWidgets('first connection asks to confirm the robot computer; a changed identity installs nothing', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const Key('remote-password')), 'secret');
      await start(tester);
      await pumpUntil(tester, find.byKey(const Key('remote-trust')));
      expect(find.text('SHA256:first-key'), findsOneWidget, reason: 'shown to confirm');
      await tester.tap(find.byKey(const Key('remote-trust')));
      await pumpUntil(tester, find.text('Remote access is on'));
      expect(session.claimedCode, 'K7QM-4XTD', reason: 'added to the account without typing a code');
      expect(signIns.single, ('secret', null, null, 'secret\n'));

      // Same address, different identity: refused without asking, nothing installed.
      await tester.pumpWidget(const SizedBox());
      fingerprint = 'SHA256:other-key';
      await open(tester);
      await tester.enterText(find.byKey(const Key('remote-password')), 'secret');
      await start(tester);
      await pumpUntil(tester, find.textContaining('different identity'));
      expect(find.byKey(const Key('remote-trust')), findsNothing);
      expect(installs, 1);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a private key signs in; the sudo password, if any, goes to sudo; the form forgets them', (tester) async {
      await open(tester);
      await tester.ensureVisible(find.text('Private key').first);
      await tester.tap(find.text('Private key').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('remote-password')), findsNothing);
      await tester.enterText(find.byKey(const Key('remote-key')), '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----');
      await tester.enterText(find.byKey(const Key('remote-passphrase')), 'phrase');
      await tester.enterText(find.byKey(const Key('remote-sudo')), 'sudo-pw');
      await start(tester);
      await pumpUntil(tester, find.byKey(const Key('remote-trust')));
      await tester.tap(find.byKey(const Key('remote-trust')));
      await pumpUntil(tester, find.text('Remote access is on'));
      final (password, key, passphrase, stdin) = signIns.single;
      expect(password, '');
      expect(key, contains('BEGIN OPENSSH PRIVATE KEY'));
      expect(passphrase, 'phrase');
      expect(stdin, 'sudo-pw\n');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('approval link', () {
    testWidgets('shows which robot is waiting and adds it only when approved', (tester) async {
      final session = FakeCloudSession(signedIn: true)..pendingRobots = {'K7QM-4XTD': (name: 'TurtleBot3', online: true)};
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(home: LinkRobotPage(code: 'k7qm-4xtd', session: session)));
      await tester.pumpAndSettle();
      expect(find.text('TurtleBot3'), findsOneWidget);
      expect(find.textContaining('Online'), findsOneWidget);
      expect(session.claimed, isFalse, reason: 'nothing happens before approval');
      await tester.tap(find.byKey(const Key('link-add')));
      await tester.pumpAndSettle();
      expect(session.claimedCode, 'K7QM-4XTD');
      expect(find.byKey(const Key('link-done')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('signing in from the link comes back to the approval, not to My robots', (tester) async {
      final session = FakeCloudSession()..pendingRobots = {'K7QM-4XTD': (name: 'TurtleBot3', online: true)};
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(home: LinkRobotPage(code: 'K7QM-4XTD', session: session)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('link-signin')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('cloud-email')), 'owner@example.com');
      await tester.enterText(find.byKey(const Key('cloud-password')), 'test-password');
      await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
      await tester.tap(find.byKey(const Key('cloud-signin')));
      await tester.pumpAndSettle();
      expect(find.text('TurtleBot3'), findsOneWidget, reason: 'back on the approval with the robot shown');
      expect(find.byKey(const Key('link-add')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('an expired or malformed code and a signed-out phone are explained', (tester) async {
      final session = FakeCloudSession(signedIn: true);
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(home: LinkRobotPage(code: 'K7QM-4XTD', session: session)));
      await tester.pumpAndSettle();
      expect(find.textContaining('invalid or expired'), findsOneWidget);
      expect(find.byKey(const Key('link-add')), findsNothing);
      await tester.pumpWidget(MaterialApp(home: LinkRobotPage(key: const Key('bad'), code: '<script>', session: session)));
      await tester.pumpAndSettle();
      expect(find.textContaining('not valid'), findsOneWidget);
      final signedOut = FakeCloudSession();
      addTearDown(signedOut.dispose);
      await tester.pumpWidget(MaterialApp(home: LinkRobotPage(key: const Key('out'), code: 'K7QM-4XTD', session: signedOut)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('link-signin')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
