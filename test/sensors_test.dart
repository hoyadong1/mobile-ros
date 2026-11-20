import 'dart:math' as math;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/monitor_page.dart';
import 'package:ros_tester/sensors.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Map<String, dynamic> q(double yaw) => {'x': 0.0, 'y': 0.0, 'z': math.sin(yaw / 2), 'w': math.cos(yaw / 2)};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('discovery keeps supported types (ROS 1 and 2 names), sorted, capped', () {
    final found = discoverSensors({
      'topics': ['/cmd_vel', '/scan', '/battery', '/imu', '/odom', '/fix'],
      'types': ['geometry_msgs/msg/Twist', 'sensor_msgs/msg/LaserScan', 'sensor_msgs/BatteryState',
        'sensor_msgs/msg/Imu', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/NavSatFix'],
    });
    expect(found.map((s) => s.topic), ['/battery', '/scan', '/imu', '/odom', '/fix']);
    expect(found.first.rosType, 'sensor_msgs/BatteryState');
    final many = discoverSensors({'topics': [for (var i = 0; i < 30; i++) '/imu$i'],
      'types': List.filled(30, 'sensor_msgs/msg/Imu')});
    expect(many, hasLength(16));
    expect(discoverSensors(null), isEmpty);
  });

  test('battery: 0..1 or 0..100 percentage, low warning unless charging', () {
    final s = decodeSensor(SensorKind.battery, {'percentage': 0.15, 'voltage': 11.1, 'current': -1.2, 'power_supply_status': 2});
    expect(s.headline, '15 %');
    expect(s.warning, 'Battery low');
    expect(s.plot, 11.1);
    expect(decodeSensor(SensorKind.battery, {'percentage': 76, 'voltage': 12.0, 'power_supply_status': 2}).headline, '76 %');
    expect(decodeSensor(SensorKind.battery, {'percentage': 0.1, 'voltage': 12.0, 'power_supply_status': 1}).warning, isNull);
    expect(decodeSensor(SensorKind.battery, {'percentage': null, 'voltage': 12.34}).headline, '12.34 V',
        reason: 'NaN percentage arrives as null');
  });

  test('LiDAR: nearest return, null/out-of-range dropped, points in the sensor frame', () {
    final s = decodeSensor(SensorKind.laser, {'angle_min': 0.0, 'angle_increment': math.pi / 2,
      'range_min': 0.12, 'range_max': 3.5, 'ranges': [1.0, null, 0.25, 0.05]});
    expect(s.headline, 'Nearest 0.25 m');
    expect(s.warning, isNotNull);
    expect(s.scan, hasLength(2));
    expect(s.scan!.last.dx, closeTo(-0.25, 1e-9));
    expect(s.details.first.$2, '180°');
  });

  test('IMU: roll/pitch from orientation, turn rate charted; missing orientation tolerated', () {
    final s = decodeSensor(SensorKind.imu, {'orientation': q(math.pi / 2), 'orientation_covariance': [0.0],
      'angular_velocity': {'x': 0, 'y': 0, 'z': 0.5}, 'linear_acceleration': {'x': 0, 'y': 0, 'z': 9.81}});
    expect(s.headline, 'Roll 0.0° · Pitch 0.0°');
    expect(s.details.first, ('Heading', '90°'));
    expect(s.plot, closeTo(28.65, 0.01));
    final noOrientation = decodeSensor(SensorKind.imu, {'orientation': q(0), 'orientation_covariance': [-1.0],
      'angular_velocity': {'x': 0, 'y': 0, 'z': 0}, 'linear_acceleration': {'x': 0, 'y': 0, 'z': 9.8}});
    expect(noOrientation.headline, startsWith('Turn rate'));
  });

  test('odometry, GPS, range', () {
    final odom = decodeSensor(SensorKind.odometry, {
      'pose': {'pose': {'position': {'x': 1.0, 'y': 2.0}, 'orientation': q(math.pi)}},
      'twist': {'twist': {'linear': {'x': -0.2, 'y': 0.0}, 'angular': {'z': 0.0}}}});
    expect(odom.plot, closeTo(-0.2, 1e-9));
    expect(odom.details, contains(('Position', '1.00, 2.00 m')));
    final gps = decodeSensor(SensorKind.gps, {'status': {'status': 0}, 'latitude': 47.397742, 'longitude': 8.545594, 'altitude': 488.0});
    expect(gps.headline, '47.397742, 8.545594');
    expect(decodeSensor(SensorKind.gps, {'status': {'status': -1}, 'latitude': null, 'longitude': null}).warning, 'No GPS fix');
    expect(decodeSensor(SensorKind.range, {'range': 5.0, 'min_range': 0.02, 'max_range': 4.0, 'radiation_type': 0}).headline,
        'Out of range');
  });

  test('custom sensor reads a nested numeric field', () {
    final sample = decodeSensor(SensorKind.custom,
      {'telemetry': {'temperature': 36.75}}, fieldPath: 'telemetry/temperature');
    expect(sample.headline, '36.75');
    expect(sample.plot, 36.75);
    expect(() => decodeSensor(SensorKind.custom, {'telemetry': {}}, fieldPath: 'telemetry/temperature'),
      throwsFormatException);
  });

  testWidgets('sensor page finds topics, subscribes throttled, shows live values and staleness', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/battery_state', '/scan', '/cmd_vel'],
      'types': ['sensor_msgs/msg/BatteryState', 'sensor_msgs/msg/LaserScan', 'geometry_msgs/msg/Twist'],
    };
    addTearDown(robot.close);
    await tester.binding.setSurfaceSize(const Size(900, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var now = DateTime(2026, 1, 1);
    DateTime advance(int ms) => now = now.add(Duration(milliseconds: ms));
    await tester.pumpWidget(MaterialApp(home: SensorPage(ip: 'r', port: '9090', connectionFactory: (_, _) => robot,
      clock: () => now)));
    await tester.pump();
    final subs = robot.sent.where((m) => m['op'] == 'subscribe').toList();
    expect(subs.map((m) => m['topic']), ['/battery_state', '/scan']);
    expect(subs.first['type'], 'sensor_msgs/msg/BatteryState');
    expect(subs.every((m) => (m['throttle_rate'] as int) > 0), isTrue);
    expect(find.text('Waiting for data'), findsNWidgets(2));

    for (var i = 0; i < 3; i++) {
      robot.events.add({'op': 'publish', 'topic': '/battery_state',
        'msg': {'percentage': 0.8 - i * 0.01, 'voltage': 12.0 - i * 0.1, 'power_supply_status': 2}});
      advance(300);
      await tester.pump(const Duration(milliseconds: 300));
    }
    robot.events.add({'op': 'publish', 'topic': '/scan', 'msg': {'angle_min': 0.0, 'angle_increment': 0.1,
      'range_min': 0.1, 'range_max': 5.0, 'ranges': [1.5, 2.0, null]}});
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('78 %'), findsOneWidget);
    expect(find.text('Nearest 1.50 m'), findsOneWidget);
    expect(find.byType(ScanView), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('sensor-state-/battery_state'))).data, endsWith('Hz'));

    advance(5000);
    await tester.pump(const Duration(seconds: 5)); // nothing new: the cards go stale
    expect(tester.widget<Text>(find.byKey(const Key('sensor-state-/scan'))).data, startsWith('No data for'));

    await tester.tap(find.byKey(const Key('sensors-refresh')));
    await tester.pump();
    expect(robot.sent.where((m) => m['op'] == 'unsubscribe').map((m) => m['topic']), ['/battery_state', '/scan']);
    expect(robot.sent.where((m) => m['op'] == 'subscribe'), hasLength(4));
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('no sensors: an explanation instead of an empty screen', (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {'topics': ['/cmd_vel'], 'types': ['geometry_msgs/msg/Twist']};
    addTearDown(robot.close);
    await tester.pumpWidget(MaterialApp(home: SensorPage(ip: 'r', port: '9090', connectionFactory: (_, _) => robot)));
    await tester.pump();
    expect(find.text('No sensor topics found'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('adds a custom namespaced topic and charts a selected ROS message field', (tester) async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/rover/payload/telemetry'],
        'types': ['vendor_msgs/msg/Telemetry'],
      }
      ..serviceResponses['/rosapi/message_details'] = {
        'typedefs': [
          {
            'type': 'vendor_msgs/Telemetry',
            'fieldnames': ['measurements'],
            'fieldtypes': ['vendor_msgs/Measurements'],
            'fieldarraylen': [-1],
            'examples': ['{}'],
            'constnames': [],
            'constvalues': [],
          },
          {
            'type': 'vendor_msgs/Measurements',
            'fieldnames': ['temperature', 'load'],
            'fieldtypes': ['float32', 'uint16'],
            'fieldarraylen': [-1, -1],
            'examples': ['0.0', '0'],
            'constnames': [],
            'constvalues': [],
          },
        ],
      };
    addTearDown(robot.close);
    await tester.pumpWidget(MaterialApp(home: SensorPage(
      ip: 'r', port: '9090', connectionFactory: (_, _) => robot,
    )));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sensors-add-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('custom-sensor-topic')), 'telemetry');
    await tester.pumpAndSettle();
    await tester.tap(find.text('/rover/payload/telemetry').last); // search, pick: fields load by themselves
    await tester.pumpAndSettle();
    expect(find.text('measurements/temperature'), findsOneWidget);
    await tester.tap(find.text('Add sensor'));
    await tester.pumpAndSettle();

    expect(robot.sent, contains(predicate<Map>((m) => m['op'] == 'subscribe' &&
        m['topic'] == '/rover/payload/telemetry' && m['type'] == 'vendor_msgs/msg/Telemetry')));
    robot.events.add({'op': 'publish', 'topic': '/rover/payload/telemetry',
      'msg': {'measurements': {'temperature': 36.75, 'load': 42}}});
    await tester.pump();
    final sensor = tester.state<SensorPageState>(find.byType(SensorPage)).feeds!.single;
    expect(sensor.source.fieldPath, 'measurements/temperature');
    expect(sensor.latest, isNotNull, reason: 'custom decode error: ${sensor.error}');
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('sensor-value-/rover/payload/telemetry'))).data, '36.75');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('custom_sensor_sources'), contains('measurements/temperature'));
    await tester.pumpWidget(const SizedBox());
  });
}
