import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/incident_recorder.dart';
import 'package:ros_tester/incidents_page.dart';

void main() {
  test('keeps the last minutes, positions only when they change, and other events stamped with the place', () {
    var now = DateTime(2026, 11, 20, 10);
    final r = IncidentRecorder(keep: const Duration(minutes: 5), clock: () => now);
    r.pose(0, 0);
    now = now.add(const Duration(seconds: 1));
    r.pose(0.01, 0); // 1 cm: not kept
    r.pose(0.5, 0);
    r.record(IncidentKind.command, 'stick: forward 0.20 m/s');
    expect(r.events.map((e) => e.kind), [IncidentKind.pose, IncidentKind.pose, IncidentKind.command]);
    expect(r.events.last.x, 0.5, reason: 'the command is placed where the robot was');
    now = now.add(const Duration(minutes: 6));
    r.record(IncidentKind.link, 'connection lost');
    expect(r.events.map((e) => e.text), ['connection lost'], reason: 'older than 5 minutes is dropped');
  });

  test('a saved incident comes back the same, newest first, and old ones are dropped past the limit', () async {
    final dir = await Directory.systemTemp.createTemp('incidents');
    addTearDown(() => dir.delete(recursive: true));
    final store = IncidentStore(folder: () async => dir, limit: 2);
    var now = DateTime(2026, 11, 20, 10);
    final r = IncidentRecorder(clock: () => now)..pose(1, 2)..record(IncidentKind.log, 'controller: no valid path', level: 'error');
    for (final reason in ['stuck', 'link lost', 'manual']) {
      await store.save(r.snapshot('robot1', reason));
      now = now.add(const Duration(seconds: 1));
    }
    final saved = await store.list();
    expect(saved.map((i) => i.reason), ['manual', 'link lost']);
    final first = saved.first;
    expect(first.robot, 'robot1');
    expect(first.path, [(1.0, 2.0)]);
    expect(first.events.last.level, 'error');
    await store.delete(first.id);
    expect((await store.list()).map((i) => i.reason), ['link lost']);
  });

  testWidgets('a record replays: the slider steps back through the events', (tester) async {
    var now = DateTime(2026, 11, 20, 10);
    final r = IncidentRecorder(clock: () => now);
    r.pose(0, 0);
    now = now.add(const Duration(seconds: 2));
    r.record(IncidentKind.command, 'manual: 0.20 m/s, 0.00 rad/s');
    now = now.add(const Duration(seconds: 2));
    r.pose(1, 0);
    r.record(IncidentKind.log, 'controller_server: no valid control', level: 'error');
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: IncidentPage(incident: r.snapshot('robot1', 'Trip failed'))));
    expect(find.text('controller_server: no valid control'), findsOneWidget);
    expect(find.byKey(const Key('incident-path')), findsOneWidget);
    final slider = tester.widget<Slider>(find.byKey(const Key('incident-time')));
    slider.onChanged!(1); // just after the stick command
    await tester.pump();
    expect(find.text('controller_server: no valid control'), findsNothing, reason: 'not yet happened');
    expect(find.text('manual: 0.20 m/s, 0.00 rad/s'), findsOneWidget);
  });
}
