// ignore_for_file: avoid_print -- progress output is the point of this manual check
// Live check of wss:// (TLS + reverse-proxy path) against scripts/wss_proxy.py in front of rosbridge.
// The proxy's throwaway CA must be passed so this test trusts it (a real robot would use a public cert):
//   flutter test tool/live_wss_test.dart --dart-define=WSS_URL=wss://<robot ip>:9443/rosbridge
//     --dart-define=CA_FILE=build/wss/ca.pem
import 'dart:async';
import 'dart:io';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/explorer_page.dart';
import 'package:ros_tester/ros_connection.dart';

const url = String.fromEnvironment('WSS_URL');
const caFile = String.fromEnvironment('CA_FILE', defaultValue: 'build/wss/ca.pem');

Future<void> waitFor(WidgetTester tester, bool Function() done, String what,
    {Duration timeout = const Duration(seconds: 20)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out after ${timeout.inSeconds}s waiting for $what');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  test('URL parsing keeps scheme, port and path', () {
    final uri = robotUri(url, '9090');
    expect(uri.scheme, 'wss');
    expect(uri.path, isNotEmpty);
    print('connecting to $uri');
  });

  test('an untrusted certificate is refused (no silent downgrade)', () async {
    final client = RosConnection(url, '9090');
    Object? error;
    try { await client.ready; } catch (e) { error = e; }
    print('without the CA: ${error.runtimeType}');
    expect(error, isNotNull);
    client.close();
  });

  test('with the CA trusted: rosapi answers and topics stream through the proxy', () async {
    SecurityContext.defaultContext.setTrustedCertificates(caFile);
    final client = RosConnection(url, '9090');
    await client.ready;
    final topics = await client.call('/rosapi/topics');
    final names = List<String>.from(topics['topics'] as List);
    print('rosapi over wss: ${names.length} topics');
    expect(names, contains('/odom'));
    final first = Completer<Map>();
    client.messages.listen((e) { if (e['topic'] == '/odom' && !first.isCompleted) first.complete(e['msg'] as Map); });
    client.send({'op': 'subscribe', 'topic': '/odom', 'throttle_rate': 200});
    final msg = await first.future.timeout(const Duration(seconds: 10));
    print('odometry over wss: x=${msg['pose']['pose']['position']['x']}');
    client.close();

    final wrongPath = RosConnection(url.replaceFirst(RegExp(r'/[^/]+$'), '/nope'), '9090');
    Object? error;
    try { await wrongPath.ready; await wrongPath.call('/rosapi/topics'); } catch (e) { error = e; }
    print('wrong path: ${error.runtimeType}');
    expect(error, isNotNull);
    wrongPath.close();
  });

  testWidgets('the explorer screen works over the wss URL', (tester) async {
    await tester.runAsync(() async => SecurityContext.defaultContext.setTrustedCertificates(caFile));
    await tester.pumpWidget(const MaterialApp(home: ExplorerPage(ip: url, port: '9090')));
    ExplorerPageState state() => tester.state<ExplorerPageState>(find.byType(ExplorerPage));
    await waitFor(tester, () => state().topicTypes.isNotEmpty || state().errorMessage != null, 'topics');
    expect(state().errorMessage, isNull);
    print('explorer over wss: ${state().topicTypes.length} topics, ${state().nodes.length} nodes');
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 6));
  });
}
