import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/cloud_session.dart';
import 'package:ros_tester/cloud_robots_page.dart';
import 'package:ros_tester/relay_access.dart';
import 'support/fake_cloud_session.dart';

http.Response response(Map<String, dynamic> value, [int status = 200]) => http.Response(jsonEncode(value), status);
Map<String, dynamic> authSession() => {'access_token': 'test-access-token', 'refresh_token': 'test-refresh-token',
  'expires_in': 3600, 'user': {'email': 'owner@example.com'}};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('billing verification stays on the authenticated gateway and cannot follow an account switch', () async {
    var verifications = 0;
    final client = CloudSession(server: 'https://relay.example', vault: MemorySessionVault(), client: MockClient((request) async {
      if (request.url.path == '/api/config') return response({'available': true, 'auth': {'provider': 'supabase'}});
      if (request.url.path == '/api/auth/signin') return response(authSession());
      if (request.url.path == '/api/billing') {
        return response({'enabled': true, 'accountId': 'a' * 64,
          'products': {'support_monthly': 1000}, 'legacySubscriptions': true});
      }
      if (request.url.path == '/api/billing/verify') {
        verifications++;
        expect(request.headers['Authorization'], 'Bearer test-access-token');
        expect(jsonDecode(request.body), {'product': 'support_monthly', 'token': 'synthetic-purchase-token', 'claimLegacy': true, 'refresh': false});
        return response({'status': 'verified', 'granted': true, 'completed': true});
      }
      if (request.url.path == '/api/account/signout') return response({'ok': true});
      return response({}, 404);
    }));
    addTearDown(client.dispose);
    await client.signIn('owner@example.com', 'synthetic-password');
    final config = await client.billingConfig();
    await client.verifyPlayPurchase('support_monthly', 'synthetic-purchase-token', version: config.version, claimLegacy: true);
    expect(verifications, 1);
    await client.signOut();
    await expectLater(client.verifyPlayPurchase('support_monthly', 'synthetic-purchase-token', version: config.version),
      throwsA(isA<CloudFailure>()));
    expect(verifications, 1, reason: 'old billing context cannot submit under a different session');
  });
  testWidgets('sharing: the owner gives a one-time code; another account joins as a viewer and can leave', (tester) async {
    final session = FakeCloudSession(signedIn: true);
    addTearDown(session.dispose);
    await tester.binding.setSurfaceSize(const Size(500, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cloud-menu-r-existing')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share…'));
    await tester.pumpAndSettle();
    expect(find.text('Sees the robot and its camera, and can always stop it. Cannot drive.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('share-viewer')));
    await tester.pumpAndSettle();
    expect(session.invites, [('r-existing', 'viewer')]);
    expect(find.byKey(const Key('share-code')), findsOneWidget);
    expect(find.text('K7QM-4XTD'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cloud-join')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('join-code')), 'join-code');
    await tester.tap(find.byKey(const Key('join-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Lab robot is now in My robots (View only).'), findsOneWidget);
    expect(find.text('Shared with you · View only'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cloud-menu-r-shared')));
    await tester.pumpAndSettle();
    expect(find.text('Share…'), findsNothing, reason: 'only the owner shares');
    await tester.tap(find.text('Leave this robot'));
    await tester.pumpAndSettle();
    expect(session.removed, [('r-shared', null)]);
    expect(find.text('Lab robot'), findsNothing);
  });

  testWidgets('small free allowances show MB and retain the hard-limit warning', (tester) async {
    final session = FakeCloudSession(signedIn: true)..claimed = true
      ..remoteUsage = const CloudUsage(100000000, 100000000, true, plan: 'free');
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Remote usage'));
    await tester.pumpAndSettle();
    expect(find.text('Free allowance'), findsOneWidget);
    expect(find.text('100.00 of 100 MB this month'), findsOneWidget);
    expect(find.textContaining('Remote access is paused'), findsOneWidget);
    for (final button in tester.widgetList<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))) {
      expect(button.onPressed, isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('failed password change drops the fenced recovery token and returns to sign in', (tester) async {
    final session = FakeCloudSession()..passwordChangeFails = true;
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session, resetToken: 'one-use-recovery')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-new-password')), 'twelve-characters');
    await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'twelve-characters');
    await tester.ensureVisible(find.byKey(const Key('cloud-save-password')));
    await tester.tap(find.byKey(const Key('cloud-save-password')));
    await tester.pumpAndSettle();
    expect(find.text('Set a new password'), findsNothing);
    expect(find.byKey(const Key('cloud-signin')), findsOneWidget);
    expect(find.textContaining('request a new reset link'), findsOneWidget);
    expect(session.newPasswords, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  test('mobile remote speed caps preserve STOP and reject unsupported velocity axes', () {
    Map<String, dynamic> command(double x, double yaw, [double y = 0]) => {'op': 'publish', 'topic': '/cmd_vel',
      'msg': {'linear': {'x': x, 'y': y, 'z': 0}, 'angular': {'x': 0, 'y': 0, 'z': yaw}}};
    final capped = limitRemoteVelocity(command(1, -2));
    expect(capped['msg']['linear']['x'], 0.25);
    expect(capped['msg']['angular']['z'], -0.6);
    expect(limitRemoteVelocity(command(0, 0))['msg']['linear']['x'], 0);
    expect(() => limitRemoteVelocity(command(0.1, 0, 0.2)), throwsStateError);
    expect(() => limitRemoteVelocity(command(double.nan, 0)), throwsStateError);
  });
  testWidgets('exhausted remote usage disables connection while nearby access remains available', (tester) async {
    final session = FakeCloudSession(signedIn: true)..claimed = true
      ..remoteUsage = const CloudUsage(5_000_000_000, 5_000_000_000, true);
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();
    for (final button in tester.widgetList<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))) {
      expect(button.onPressed, isNull);
    }
    await tester.ensureVisible(find.text('Remote usage')); await tester.pumpAndSettle();
    expect(find.text('5.00 of 5 GB this month'), findsOneWidget);
    expect(find.text('Connect nearby'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test('sign-in uses the HTTPS gateway without app API keys; refresh uses vault and tickets stay out of preferences', () async {
    SharedPreferences.setMockInitialValues({});
    await RelayAccess.load();
    final vault = MemorySessionVault();
    final client = CloudSession(server: 'https://relay.example', vault: vault, client: MockClient((request) async {
      if (request.url.path == '/api/config') {
        return response({'available': true,
          'auth': {'provider': 'supabase'}});
      }
      if (request.url.path == '/api/auth/signin') {
        expect(request.url.host, 'relay.example');
        expect(request.headers.containsKey('apikey'), false);
        expect(jsonDecode(request.body)['password'], 'test-password');
        return response(authSession());
      }
      expect(request.url.host, 'relay.example');
      expect(request.headers['Authorization'], 'Bearer test-access-token');
      if (request.url.path.endsWith('/access')) {
        return response({'token': 'temporary_ticket', 'address': 'wss://relay.example/robots/r-test', 'expiresAt': 1});
      }
      if (request.url.path == '/api/robots') return response({'robots': []});
      return response({'ok': true});
    }));
    addTearDown(client.dispose);
    await client.signIn('owner@example.com', 'test-password');
    expect(client.signedIn, true);
    expect(await vault.read(), 'test-refresh-token');
    await client.ticket(const CloudRobot('r-test', 'Robot', true));
    expect(RelayAccess.tokenFor('wss://relay.example/robots/r-test'), 'temporary_ticket');
    expect((await SharedPreferences.getInstance()).getString('relay_tokens'), isNull);
    // No password, access JWT or robot ticket was persisted to preferences.
    await client.signOut();
    expect(client.signedIn, false);
    expect(await vault.read(), isNull);
    expect(RelayAccess.tokenFor('wss://relay.example/robots/r-test'), isNull);
  });
  test('saved sign-in is refreshed without saving the user password', () async {
    final vault = MemorySessionVault();
    await vault.write('old-refresh');
    final client = CloudSession(server: 'https://relay.example', vault: vault, client: MockClient((request) async {
      if (request.url.path == '/api/config') {
        return response({'available': true,
          'auth': {'provider': 'supabase'}});
      }
      expect(request.url.path, '/api/auth/refresh');
      expect(jsonDecode(request.body), {'refresh_token': 'old-refresh'});
      return response(authSession());
    }));
    addTearDown(client.dispose);
    await client.restore();
    expect(client.email, 'owner@example.com');
    expect(await vault.read(), 'test-refresh-token');
  });
  test('untrusted ticket host is refused and provider errors do not echo credentials', () async {
    var invalidPassword = false;
    final client = CloudSession(server: 'https://relay.example', vault: MemorySessionVault(), client: MockClient((request) async {
      if (request.url.path == '/api/config') {
        return response({'available': true,
          'auth': {'provider': 'supabase'}});
      }
      if (request.url.path == '/api/auth/signin') {
        return invalidPassword ? response({'error_code': 'invalid_credentials', 'message': 'private upstream details'}, 400) : response(authSession());
      }
      return response({'token': 'ticket', 'address': 'wss://someone-else.example/robots/r-test'});
    }));
    addTearDown(client.dispose);
    await client.signIn('owner@example.com', 'test-password');
    await expectLater(client.ticket(const CloudRobot('r-test', 'Robot', true)), throwsA(isA<CloudFailure>()));
    invalidPassword = true;
    await expectLater(client.signIn('owner@example.com', 'test-password'), throwsA(predicate((error) =>
      error is CloudFailure && !error.message.contains('private upstream') && !error.message.contains('test-password'))));
  });
  test('a temporary network failure does not erase the saved refresh token', () async {
    final vault = MemorySessionVault();
    await vault.write('saved-refresh');
    final client = CloudSession(server: 'https://relay.example', vault: vault, client: MockClient((request) async {
      if (request.url.path == '/api/config') {
        return response({'available': true,
          'auth': {'provider': 'supabase'}});
      }
      throw http.ClientException('offline');
    }));
    addTearDown(client.dispose);
    await expectLater(client.restore(), throwsA(isA<CloudFailure>()));
    expect(await vault.read(), 'saved-refresh');
    expect(client.signedIn, false);
  });

  for (final size in [const Size(320, 640), const Size(800, 1280), const Size(1280, 800)]) {
    testWidgets('My robots sign-in and registration fit $size at 200% text', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = FakeCloudSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(MaterialApp(theme: buildTheme(Brightness.light), builder: (context, child) =>
        MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
        home: CloudRobotsPage(session: session)));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byKey(const Key('cloud-email')), 'owner@example.com');
      await tester.enterText(find.byKey(const Key('cloud-password')), 'test-password');
      await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
      await tester.tap(find.byKey(const Key('cloud-signin')));
      await tester.pumpAndSettle();
      expect(find.text('Warehouse robot'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('cloud-add')));
      await tester.tap(find.byKey(const Key('cloud-add')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cloud-claim-code')));
      expect(find.text('curl -fsSL https://relay.example/i | sudo bash'), findsOneWidget,
          reason: 'one command for every robot; the account is chosen by approving');
      await tester.enterText(find.byKey(const Key('cloud-claim-code')), 'k7qm 4xtd');
      await tester.ensureVisible(find.byKey(const Key('cloud-register')));
      await tester.tap(find.byKey(const Key('cloud-register')));
      await tester.pumpAndSettle();
      expect(session.claimed, true);
      expect(session.claimedCode, 'K7QM-4XTD', reason: 'typed as read, sent normalized');
      expect(find.text('New robot'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('account creation returns to sign-in with email verification guidance', (tester) async {
    final session = FakeCloudSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('cloud-switch-mode')));
    await tester.tap(find.byKey(const Key('cloud-switch-mode')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-email')), 'owner@example.com');
    await tester.enterText(find.byKey(const Key('cloud-password')), 'twelve-characters');
    await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'different-password');
    await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
    await tester.tap(find.byKey(const Key('cloud-signin')));
    await tester.pumpAndSettle();
    expect(find.text('Passwords do not match.'), findsOneWidget);
    expect(find.text('Check your email'), findsNothing);
    await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'twelve-characters');
    await tester.ensureVisible(find.byKey(const Key('cloud-signin')));
    await tester.tap(find.byKey(const Key('cloud-signin')));
    await tester.pumpAndSettle();
    expect(find.text('Check your email'), findsOneWidget);
    expect(find.byKey(const Key('cloud-email')), findsNothing);
    expect(session.signedIn, false);
    await tester.tap(find.byKey(const Key('cloud-email-confirmed')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cloud-email')), findsOneWidget);
    expect(find.byKey(const Key('cloud-confirm-password')), findsNothing);
    expect(find.text('Sign in to finish setting up your account.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('password reset, new password and account deletion go through the HTTPS gateway; deletion clears the saved sign-in', () async {
    final vault = MemorySessionVault();
    final seen = <String>[];
    final client = CloudSession(server: 'https://relay.example', vault: vault, client: MockClient((request) async {
      if (request.url.path == '/api/config') return response({'available': true, 'auth': {'provider': 'supabase'}});
      seen.add('${request.method} ${request.url.path} ${request.headers['Authorization'] ?? ''} ${request.body}');
      if (request.url.path == '/api/auth/signin') return response(authSession());
      if (request.url.path == '/api/account') return response({'deleted': true, 'pending': false});
      return response({'ok': true});
    }));
    addTearDown(client.dispose);
    await client.requestPasswordReset(' owner@example.com ');
    await client.setNewPassword('reset-link-token', 'a-new-long-password');
    await client.signIn('owner@example.com', 'test-password');
    expect(await vault.read(), 'test-refresh-token');
    expect(await client.deleteAccount('test-password'), isTrue);
    expect(seen[0], contains('POST /api/auth/recover'));
    expect(seen[0], contains('"email":"owner@example.com"'));
    expect(seen[1], startsWith('POST /api/account/password Bearer reset-link-token'));
    expect(seen.last, startsWith('DELETE /api/account Bearer test-access-token'));
    expect(seen.last, contains('"password":"test-password"'));
    expect(client.signedIn, isFalse);
    expect(await vault.read(), isNull, reason: 'no saved sign-in remains');
  });
  testWidgets('forgot password sends a reset link; a reset link sets the new password', (tester) async {
    final session = FakeCloudSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cloud-email')), 'owner@example.com');
    await tester.ensureVisible(find.byKey(const Key('cloud-forgot')));
    await tester.tap(find.byKey(const Key('cloud-forgot')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const Key('cloud-reset-email'))).controller!.text, 'owner@example.com');
    await tester.tap(find.byKey(const Key('cloud-reset-send')));
    await tester.pumpAndSettle();
    expect(session.resetRequests, ['owner@example.com']);
    expect(find.textContaining('a reset link is on its way'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    final reset = FakeCloudSession();
    addTearDown(reset.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: reset, resetToken: 'reset-link-token')));
    await tester.pumpAndSettle();
    expect(find.text('Set a new password'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('cloud-new-password')), 'short');
    await tester.tap(find.byKey(const Key('cloud-save-password')));
    await tester.pumpAndSettle();
    expect(reset.newPasswords, isEmpty);
    await tester.enterText(find.byKey(const Key('cloud-new-password')), 'a-new-long-password');
    await tester.enterText(find.byKey(const Key('cloud-confirm-password')), 'a-new-long-password');
    await tester.tap(find.byKey(const Key('cloud-save-password')));
    await tester.pumpAndSettle();
    expect(reset.newPasswords, [('reset-link-token', 'a-new-long-password')]);
    expect(find.text('Set a new password'), findsNothing);
    expect(find.byKey(const Key('cloud-email')), findsOneWidget, reason: 'back to sign-in');
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('account deletion asks for the password and leaves the person signed out', (tester) async {
    final session = FakeCloudSession(signedIn: true);
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(home: CloudRobotsPage(session: session)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('cloud-delete-account')));
    await tester.tap(find.byKey(const Key('cloud-delete-account')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('cloud-delete-confirm'))).onPressed, isNull,
        reason: 'not without the password');
    await tester.enterText(find.byKey(const Key('cloud-delete-password')), 'test-password');
    await tester.pump();
    await tester.tap(find.byKey(const Key('cloud-delete-confirm')));
    await tester.pumpAndSettle();
    expect(session.deletedWith, 'test-password');
    expect(find.textContaining('are deleted'), findsOneWidget);
    expect(find.byKey(const Key('cloud-email')), findsOneWidget, reason: 'signed out');
    await tester.pumpWidget(const SizedBox());
  });
}
