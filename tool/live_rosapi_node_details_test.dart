// ignore_for_file: avoid_print -- progress output is the point of this manual check
// rosbridge_suite's rosapi crashes (and stays down) when /rosapi/node_details is asked about a node it does
// not list. 1) shows the robot-side bug with a raw call, 2) shows the app's node page does not trigger it.
// Run against a rosbridge on a robot or WSL distro (restart rosbridge between runs: test 1 kills rosapi):
//   flutter test tool/live_rosapi_node_details_test.dart [--dart-define=PORT=9090] [--dart-define=RAW=1]
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/explorer_page.dart';
import 'package:ros_tester/ros_connection.dart';

const host = String.fromEnvironment('HOST', defaultValue: '127.0.0.1');
const port = String.fromEnvironment('PORT', defaultValue: '9090');
const raw = bool.fromEnvironment('RAW');

Future<List?> nodes(RosConnection c) async {
  for (var i = 0; i < 20; i++) {
    try {
      return (await c.call('/rosapi/nodes').timeout(const Duration(seconds: 5)))['nodes'] as List?;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 500)); // rosapi starts after rosbridge
    }
  }
  return null;
}

void main() {
  testWidgets('the node page for a node that is not there leaves rosapi running', (tester) async {
    late RosConnection c;
    await tester.runAsync(() async {
      c = RosConnection(host, port); // real time: the widget test's fake clock would stall the socket
      await c.ready;
      print('nodes before: ${await nodes(c)}');
    });
    if (raw) {
      await tester.runAsync(() async {
        try {
          await c.call('/rosapi/node_details', {'node': '/no_such_node'}).timeout(const Duration(seconds: 6));
        } catch (e) {
          print('raw node_details(/no_such_node): $e');
        }
      });
    } else {
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(home: NodeDetailPage(connection: c, node: '/no_such_node')));
        await Future<void>.delayed(const Duration(seconds: 3));
      });
      await tester.pump();
      print('page shows: ${find.textContaining('not running').evaluate().isNotEmpty ? 'not running' : '?'}');
    }
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 1));
      final after = await nodes(c);
      print(after == null ? 'rosapi is gone' : 'rosapi still answers: $after');
      expect(after, isNotNull, reason: raw ? 'the robot-side bug (expected to fail)' : 'the app must not crash rosapi');
      c.close();
    });
  });
}
