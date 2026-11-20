import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/plot_page.dart';
import 'package:ros_tester/plotting.dart';
import 'package:ros_tester/sensors.dart';

import 'support/fake_ros_connection.dart';

Map<String, dynamic> _odom(double vx, double wz) => {
  'header': {'stamp': {'sec': 1, 'nanosec': 2}, 'frame_id': 'odom'},
  'pose': {'pose': {'position': {'x': 1.0, 'y': 2.0, 'z': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}},
    'covariance': List.filled(36, 0.0)},
  'twist': {'twist': {'linear': {'x': vx, 'y': 0.0, 'z': 0.0}, 'angular': {'x': 0.0, 'y': 0.0, 'z': wz}},
    'covariance': List.filled(36, 0.0)},
};

void main() {
  test('reads shown numbers, paths, and every number of a message', () {
    expect(parseShownNumber('12.30 V'), (12.3, 'V'));
    expect(parseShownNumber('45°'), (45.0, '°'));
    expect(parseShownNumber('-0.5 m/s'), (-0.5, 'm/s'));
    expect(parseShownNumber('—').$1, isNull);
    expect(readPath(_odom(0.2, 0), 'twist.twist.linear.x'), 0.2);
    expect(readPath({'a': [1, 2, 3]}, 'a[2]'), 3.0);
    expect(readPath({'a': [1]}, 'a[4]'), isNull);
    final fields = numericFields(_odom(0.2, 0.1));
    expect(fields['twist.twist.angular.z'], 0.1);
    expect(fields.keys.any((k) => k.startsWith('header')), isFalse);
    expect(fields.keys.any((k) => k.contains('covariance')), isFalse, reason: '36 elements: too long to list');
    expect(numericFields({'ok': true})['ok'], 1.0);
  });

  test('the buffer keeps a window, thins long series without losing spikes, and sums up', () {
    final b = PlotBuffer(keep: const Duration(seconds: 60));
    final t0 = DateTime(2026, 11, 14, 12);
    final f = pathField('v');
    for (var i = 0; i < 1000; i++) {
      b.add(t0.add(Duration(milliseconds: i * 50)), {'v': i == 500 ? 100.0 : 1.0}, [f]);
    }
    final now = t0.add(const Duration(milliseconds: 999 * 50));
    final pts = b.points(f.id, now, const Duration(seconds: 60), maxPoints: 100);
    expect(pts.length, lessThanOrEqualTo(100));
    expect(pts.map((p) => p.$2), contains(100.0), reason: 'the spike survives thinning');
    final st = b.stats(f.id, now, const Duration(seconds: 60))!;
    expect(st.max, 100);
    expect(st.min, 1);
    expect(st.last, 1);
    b.add(now.add(const Duration(seconds: 120)), {'v': 2.0}, [f]);
    expect(b.series[f.id], hasLength(1), reason: 'older than keep');
  });

  test('a sensor value is read the way its card shows it', () {
    final f = sensorField(SensorKind.battery, 'Voltage', unit: 'V');
    expect(f.read({'voltage': 12.3, 'current': -1.0, 'percentage': 0.8, 'power_supply_status': 2}), closeTo(12.3, 1e-9));
  });

  testWidgets('graph screen: live values, stats, another field, pause', (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    var now = DateTime(2026, 11, 14, 12);
    await tester.pumpWidget(MaterialApp(home: PlotPage(connection: robot, topic: '/odom',
        fields: [pathField('twist.twist.linear.x')], clock: () => now)));
    expect(robot.sent.single['op'], 'subscribe');
    expect(find.byKey(const Key('plot-waiting')), findsOneWidget);
    for (var i = 0; i < 20; i++) {
      now = now.add(const Duration(milliseconds: 100));
      robot.events.add({'op': 'publish', 'topic': '/odom', 'msg': _odom(i / 100, 0.3)});
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.byType(LineChart), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('plot-value-twist.twist.linear.x'))).data, '0.190');
    expect(find.textContaining('min 0.000 · max 0.190'), findsOneWidget);

    await tester.tap(find.byKey(const Key('plot-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('plot-field-search')), 'angular.z');
    await tester.pumpAndSettle();
    await tester.tap(find.text('twist.twist.angular.z'));
    await tester.pumpAndSettle();
    now = now.add(const Duration(milliseconds: 100));
    robot.events.add({'op': 'publish', 'topic': '/odom', 'msg': _odom(0.2, 0.3)});
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.widget<Text>(find.byKey(const Key('plot-value-twist.twist.angular.z'))).data, '0.300');

    await tester.tap(find.byKey(const Key('plot-pause')));
    await tester.pump();
    expect(find.textContaining('Paused'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    expect(robot.sent.last['op'], 'unsubscribe');
  });
}
