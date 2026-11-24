import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/diagnostics.dart';
import 'package:ros_tester/diagnostics_page.dart';
import 'package:ros_tester/topic_health_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Map<String, Object?> report(String name, Object level, String message, [Map<String, String> values = const {}]) => {
  'name': name, 'level': level, 'message': message, 'hardware_id': 'hw-$name',
  'values': [for (final e in values.entries) {'key': e.key, 'value': e.value}],
};

Map<String, Object?> array(List<Map<String, Object?>> status) => {'header': {'stamp': {'sec': 1, 'nanosec': 0}}, 'status': status};

void main() {
  final t0 = DateTime(2026, 11, 24, 12);

  test('the level is read however the bridge sends a byte', () {
    expect(parseDiagLevel(0), DiagLevel.ok);
    expect(parseDiagLevel(2), DiagLevel.error);
    expect(parseDiagLevel('1'), DiagLevel.warn);
    expect(parseDiagLevel('\u0002'), DiagLevel.error);
    expect(parseDiagLevel('AQ=='), DiagLevel.warn, reason: 'base64 of one byte');
    expect(parseDiagLevel([3]), DiagLevel.stale);
    expect(parseDiagLevel(null), DiagLevel.stale);
  });

  test('latest report per name, worst first; a report not repeated turns stale', () {
    final b = DiagnosticsBoard();
    b.update(array([report('/Robot/Motors/Left', 0, 'OK'), report('/Robot/Battery', 1, 'Low'),
      report('lidar: scan rate', 2, 'Frequency too low')]), t0);
    expect(b.sorted(t0).map((s) => s.name), ['lidar: scan rate', '/Robot/Battery', '/Robot/Motors/Left']);
    final left = b.sorted(t0).last;
    expect(left.shortName, 'Left');
    expect(left.group, 'Robot / Motors');
    expect(b.sorted(t0).first.group, '', reason: 'a plain updater name has no group');

    final later = t0.add(const Duration(seconds: 12));
    b.update(array([report('lidar: scan rate', 0, 'OK'), report('/Robot/Battery', 1, 'Low')]), later);
    expect(b.levelOf(b.sorted(later).firstWhere((s) => s.name == '/Robot/Motors/Left'), later), DiagLevel.stale);
    expect(b.counts(later), {DiagLevel.ok: 1, DiagLevel.warn: 1, DiagLevel.error: 0, DiagLevel.stale: 1});
  });

  test('an error is announced once, again only after the part was OK', () {
    final a = DiagnosticsAlerts();
    final b = DiagnosticsBoard();
    List<String> step(List<Map<String, Object?>> s) => a.newErrors(b.update(array(s), t0)).map((e) => e.name).toList();
    expect(step([report('motor', 2, 'Overcurrent')]), ['motor']);
    expect(step([report('motor', 2, 'Overcurrent')]), isEmpty);
    expect(step([report('motor', 1, 'Warm')]), isEmpty, reason: 'a warning does not re-arm');
    expect(step([report('motor', 2, 'Overcurrent')]), isEmpty);
    expect(step([report('motor', 0, 'OK')]), isEmpty);
    expect(step([report('motor', 2, 'Overcurrent')]), ['motor']);
  });

  test('the aggregated topic is preferred', () {
    expect(pickDiagnosticsTopic({'/diagnostics': 'diagnostic_msgs/msg/DiagnosticArray',
      '/diagnostics_agg': 'diagnostic_msgs/msg/DiagnosticArray', '/odom': 'nav_msgs/msg/Odometry'}), '/diagnostics_agg');
    expect(pickDiagnosticsTopic({'/odom': 'nav_msgs/msg/Odometry'}), isNull);
  });

  testWidgets('the page shows counts, errors first with details, and filters to problems', (tester) async {
    final r = FakeConnection();
    addTearDown(r.close);
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: DiagnosticsPage(connection: r, topic: '/diagnostics', clock: () => t0)));
    final sub = r.sent.single;
    expect(sub['op'], 'subscribe');
    expect(sub['id'], isA<String>());
    r.events.add({'op': 'publish', 'topic': '/diagnostics', 'msg': array([
      report('base: motors', 0, 'OK'), report('base: battery', 1, 'Low voltage', {'Voltage': '10.9'}),
      report('lidar', 2, 'No data for 3 s')])});
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(find.byKey(const Key('diag-count-error'))).data, 'Error 1');
    expect(tester.widget<Text>(find.byKey(const Key('diag-count-warn'))).data, 'Warning 1');
    final order = [for (final w in tester.widgetList<Card>(find.byType(Card))) w.key]
        .whereType<ValueKey<String>>().map((k) => k.value).where((k) => k.startsWith('diag-') && k != 'diag-summary').toList();
    expect(order, ['diag-lidar', 'diag-base: battery', 'diag-base: motors']);
    await tester.tap(find.text('base: battery'));
    await tester.pumpAndSettle();
    expect(find.text('10.9'), findsOneWidget);
    await tester.tap(find.byKey(const Key('diag-problems-only')));
    await tester.pumpAndSettle();
    expect(find.text('base: motors'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(r.sent.last, {'op': 'unsubscribe', 'id': sub['id'], 'topic': '/diagnostics'});
  });

  testWidgets('topic health links to diagnostics when the robot has them', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final r = FakeConnection();
    addTearDown(r.close);
    await tester.pumpWidget(MaterialApp(home: TopicHealthPage(connection: r, topicTypes: const {
      '/scan': 'sensor_msgs/msg/LaserScan', '/diagnostics': 'diagnostic_msgs/msg/DiagnosticArray'})));
    await tester.pump();
    await tester.tap(find.byKey(const Key('health-diagnostics')));
    await tester.pumpAndSettle();
    expect(find.text('Robot diagnostics'), findsOneWidget);
    expect(r.sent.where((m) => m['op'] == 'subscribe').map((m) => m['topic']), contains('/diagnostics'));
    await tester.pumpWidget(const SizedBox());
  });
}
