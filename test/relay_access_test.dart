import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/main.dart';
import 'package:ros_tester/connect_page.dart';
import 'package:ros_tester/relay_access.dart';
import 'package:ros_tester/ros_connection.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a relay address is recognised; its saved token travels as a subprotocol', () async {
    SharedPreferences.setMockInitialValues({});
    await RelayAccess.load();
    expect(RelayAccess.isRelay('wss://relay.example.com/robots/turtle-1'), isTrue);
    expect(RelayAccess.isRelay('ws://192.168.0.5:8780/robots/turtle-1'), isTrue);
    expect(RelayAccess.isRelay('wss://robot.example/rosbridge'), isFalse, reason: 'a robot\'s own rosbridge');
    expect(RelayAccess.isRelay('192.168.1.10'), isFalse);
    expect(RelayAccess.isRelay('wss://relay.example.com:0/robots/turtle-1'), isFalse);
    expect(() => robotUri('wss://relay.example.com:0/robots/turtle-1', '9090'), throwsFormatException);
    expect(RelayAccess.protocolsFor(Uri.parse('wss://relay.example.com/robots/turtle-1')), isNull);
    await RelayAccess.save('wss://Relay.example.com/robots/turtle-1/', ' secret-token ');
    expect(RelayAccess.protocolsFor(Uri.parse('wss://relay.example.com/robots/turtle-1')), ['bearer.secret-token']);
    await RelayAccess.load();
    expect(RelayAccess.tokenFor('wss://relay.example.com/robots/turtle-1'), 'secret-token', reason: 'kept');
    await RelayAccess.save('wss://relay.example.com/robots/turtle-1', '');
    expect(RelayAccess.tokenFor('wss://relay.example.com/robots/turtle-1'), isNull);
  });

  test('relay URLs use their own port and preserve case-sensitive robot identities', () async {
    SharedPreferences.setMockInitialValues({});
    await RelayAccess.load();
    await RelayAccess.save('wss://Relay.example.com/robots/Robot-A/', 'Token-A');
    final uri = robotUri('wss://relay.example.com/robots/Robot-A/', '9090');
    expect(uri.toString(), 'wss://relay.example.com/robots/Robot-A');
    expect(RelayAccess.protocolsFor(uri), ['bearer.Token-A']);
    expect(RelayAccess.tokenFor('wss://relay.example.com/robots/robot-a'), isNull);
    expect(robotUri('ws://localhost:8780/robots/robot-a', '9090').port, 8780);
    expect(RelayAccess.isRelay('wss://user:secret@relay.example.com/robots/Robot-A'), isFalse);
    expect(RelayAccess.isRelay('wss://relay.example.com/ROBOTS/Robot-A'), isFalse);
    expect(RelayAccess.validToken('a\r\nb'), isFalse);
    await expectLater(RelayAccess.save(uri.toString(), 'bad token'), throwsFormatException);
  });

  test('invalid stored tokens are discarded before a WebSocket handshake', () async {
    SharedPreferences.setMockInitialValues({'relay_tokens':
      '{"wss://relay.example.com/robots/robot-a":"bad token","192.168.0.1":"secret"}'});
    await RelayAccess.load();
    expect(RelayAccess.tokenFor('wss://relay.example.com/robots/robot-a'), isNull);
  });

  for (final size in [const Size(320, 640), const Size(800, 1280), const Size(1280, 800)]) {
    testWidgets('relay form remains usable with 200% text at $size', (tester) async {
      SharedPreferences.setMockInitialValues({});
      await RelayAccess.load();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)), child: child!),
        home: const ConnectPage()));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('robot-host')), 'wss://relay.example.com/robots/robot-a');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('relay-token')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byKey(const Key('connect-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('robot-port')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a relay address asks for the access token; a robot address does not', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await RelayAccess.load();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('robot-host')), '192.168.1.20');
    await tester.pump();
    expect(find.byKey(const Key('relay-token')), findsNothing);
    await tester.enterText(find.byKey(const Key('robot-host')), 'wss://relay.example.com/robots/turtle-1');
    await tester.pump();
    expect(find.byKey(const Key('relay-token')), findsOneWidget);
    expect(find.byKey(const Key('robot-port')), findsNothing);
    await tester.enterText(find.byKey(const Key('relay-token')), 'robot-one-secret');
    await tester.enterText(find.byKey(const Key('robot-host')), 'wss://relay.example.com/robots/turtle-2');
    await tester.pump();
    expect(tester.widget<TextFormField>(find.byKey(const Key('relay-token'))).controller!.text, isEmpty,
        reason: 'never carry a token to another robot');
  });
}
