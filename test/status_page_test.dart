import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/robot_log.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/status_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Map<String, dynamic> _warn(String text) => {
  'stamp': {'sec': 1700000000, 'nanosec': 0}, 'level': 30, 'name': 'amcl', 'msg': text,
};

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('tablet shows sensors and logs together; hidden phone logs do not consume new warnings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection()..serviceResponses['/rosapi/topics_and_raw_types'] = {'topics': [], 'types': []};
    addTearDown(robot.close);
    final log = RobotLog(RosClient(robot));
    var connections = 0;
    await tester.pumpWidget(MaterialApp(home: RobotStatusPage(ip: 'robot', port: '9090', log: log,
      connectionFactory: (_, _) { connections++; return robot; })));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('tool-panes')), findsOneWidget);
    expect(find.byKey(const Key('log-search-toggle')).hitTestable(), findsOneWidget);
    log.add(_warn('Visible tablet warning'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(log.unseenProblems, 0);

    await tester.binding.setSurfaceSize(const Size(390, 800));
    await tester.pumpAndSettle();
    log.add(_warn('Hidden phone warning'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(log.unseenProblems, 1, reason: 'a previously opened but now hidden log must not mark warnings seen');
    expect(connections, 1, reason: 'rotation must keep the same sensor session');
    await tester.tap(find.byKey(const Key('status-tab-log')));
    await tester.pumpAndSettle();
    expect(log.unseenProblems, 0);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('sensors and the log on one screen: offline it opens on the log, which is read only when shown',
      (tester) async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    final log = RobotLog(RosClient(robot))..add(_warn('No laser scan received'));
    expect(log.unseenProblems, 1);
    await tester.pumpWidget(MaterialApp(home: RobotStatusPage(ip: 'robot', port: '9090', log: log, online: false,
        connectionFactory: (_, _) => robot)));
    await tester.pump();
    expect(find.textContaining('No laser scan received'), findsOneWidget);
    expect(find.textContaining('No laser scan received'), findsOneWidget);
    expect(log.unseenProblems, 0, reason: 'the log was looked at');
    expect(find.byKey(const Key('status-tab-sensors')), findsNothing, reason: 'no sensors without a connection');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('online it opens on the sensors; the Log tab shows the count of new problems until opened',
      (tester) async {
    final robot = FakeConnection()..serviceResponses['/rosapi/topics_and_raw_types'] = {'topics': [], 'types': []};
    addTearDown(robot.close);
    final log = RobotLog(RosClient(robot));
    await tester.pumpWidget(MaterialApp(home: RobotStatusPage(ip: 'robot', port: '9090', log: log,
        connectionFactory: (_, _) => robot)));
    await tester.pump();
    expect(find.text('Sensors'), findsWidgets);
    expect(find.byKey(const Key('log-search-toggle')), findsNothing, reason: 'built when first shown');
    log.add(_warn('Costmap is out of date'));
    await tester.pump(const Duration(milliseconds: 300)); // the log tells its listeners every 200 ms
    expect(log.unseenProblems, 1, reason: 'not seen while the sensors are shown');
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('status-tab-log')));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Costmap is out of date'), findsOneWidget);
    expect(log.unseenProblems, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
