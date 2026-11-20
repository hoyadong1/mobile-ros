import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/fleet_server_client.dart';
import 'package:ros_tester/fleet_server_page.dart';

void main() {
  testWidgets('server dashboard shows fleet and records a validated task', (tester) async {
    var tasks = <Map<String, dynamic>>[];
    var stops = 0;
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer operator-test-token');
      if (request.url.path == '/api/map') return http.Response('{}', 200);
      if (request.url.path == '/api/state') {
        return http.Response.bytes(utf8.encode(jsonEncode({
          'connected': true,
          'robots': [
            {'id': 'robot1', 'status': 'online', 'battery': 0.75,
              'pose': {'x': 1.0, 'y': 2.0, 'yaw': 0}, 'error': null},
            {'id': 'robot2', 'status': 'online', 'battery': null, 'pose': null, 'error': null},
          ],
          'places': ['Inspection station'], 'tasks': tasks, 'events': [],
        })), 200, headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (request.url.path == '/api/tasks') {
        expect(jsonDecode(request.body), {'robot': 'robot1', 'destination': 'Inspection station'});
        tasks = [{'id': 'task1', 'robot': 'robot1', 'destination': 'Inspection station',
          'status': 'active', 'updatedAt': 'now'}];
        return http.Response.bytes(utf8.encode(jsonEncode({'task': tasks.first})), 202,
          headers: {'content-type': 'application/json; charset=utf-8'});
      }
      if (request.url.path == '/api/stop_all') {
        stops++;
        return http.Response('{"stopped":true}', 200);
      }
      return http.Response('{"error":"Unexpected route"}', 404);
    });
    final api = FleetServerClient('http://127.0.0.1:8766', 'operator-test-token', client: client);
    final state = await api.state();
    await tester.binding.setSurfaceSize(const Size(900, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: FleetServerDashboard(client: api, initialState: state)));
    await tester.pump();
    expect(find.byKey(const Key('server-robot-robot1')), findsOneWidget);
    expect(find.byKey(const Key('server-robot-robot2')), findsOneWidget);
    expect(find.text('Battery: 75%'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fleet-task-new')));
    await tester.pump();
    await tester.tap(find.text('Request task').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('robot1 → Inspection station'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fleet-stop-all')));
    await tester.pump();
    expect(stops, 1);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets('a cancel waiting for the robot and a silent robot are shown in words', (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/map') return http.Response('{}', 200);
      return http.Response.bytes(utf8.encode(jsonEncode({
        'connected': true,
        'robots': [
          {'id': 'robot1', 'status': 'stale', 'battery': null, 'pose': null, 'error': 'No data from the robot.',
            'floor': '2F'},
        ],
        'places': ['Dock'], 'events': [],
        'tasks': [
          {'id': 'a1', 'robot': 'robot1', 'destination': 'Dock', 'status': 'canceling', 'updatedAt': 'now',
            'step': 'Riding LIFT1 to 2F'},
          {'id': 'b2', 'robot': 'robot1', 'destination': 'Dock', 'status': 'cancel_unconfirmed',
            'error': 'The robot did not confirm the cancel. Check it.', 'updatedAt': 'now'},
        ],
      })), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    final api = FleetServerClient('http://127.0.0.1:8766', 'operator-test-token', client: client);
    final state = await api.state();
    await tester.binding.setSurfaceSize(const Size(900, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: FleetServerDashboard(client: api, initialState: state)));
    await tester.pump();
    expect(find.text('robot1 · no recent data · 2F'), findsOneWidget);
    expect(find.textContaining('Riding LIFT1 to 2F'), findsOneWidget, reason: 'where a lift trip is');
    expect(find.textContaining('Canceling (waiting for the robot)'), findsOneWidget);
    expect(find.textContaining('Cancel not confirmed'), findsOneWidget);
    expect(find.byTooltip('Ask again to cancel'), findsNWidgets(2), reason: 'not confirmed yet: may ask again');
    await tester.pumpWidget(const SizedBox());
    api.close();
  });

  testWidgets('the site map is fetched again only when its version changes', (tester) async {
    var version = 1, mapFetches = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/api/map') {
        mapFetches++;
        return http.Response(jsonEncode({'version': version}), 200);
      }
      return http.Response(jsonEncode({'connected': true, 'robots': [], 'places': [], 'tasks': [], 'events': [],
        'mapVersion': version}), 200);
    });
    final api = FleetServerClient('http://127.0.0.1:8766', 'operator-test-token', client: client);
    final state = await api.state();
    await tester.pumpWidget(MaterialApp(home: FleetServerDashboard(client: api, initialState: state)));
    await tester.pump();
    for (var i = 0; i < 20; i++) { await tester.pump(const Duration(seconds: 2)); }
    expect(mapFetches, 1, reason: '40 s with the same map: no new download');
    version = 2;
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(mapFetches, 2);
    await tester.pumpWidget(const SizedBox());
    api.close();
  });
}
