import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/connect_page.dart';
import 'package:ros_tester/main.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('connection form has a default port and rejects an empty host', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    final port = tester.widget<TextFormField>(find.byKey(const Key('robot-port')));
    expect(port.controller!.text, '9090');
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a host/IP or a valid ws:// or wss:// URL.'), findsOneWidget);
    expect(find.text('Connecting…'), findsNothing);
  });

  testWidgets('Zenoh mode asks for the router address and the domain ID, and is remembered', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zenoh'));
    await tester.pumpAndSettle();
    expect(find.text('Robot address'), findsOneWidget);
    expect(find.text('ROS_DOMAIN_ID'), findsOneWidget);
    final port = tester.widget<TextFormField>(find.byKey(const Key('robot-port')));
    expect(port.controller!.text, '0');
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(find.text('Enter the robot address.'), findsOneWidget);
    expect((await SharedPreferences.getInstance()).getString('connection_mode'), 'zenoh');

    await tester.tap(find.text('rosbridge'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextFormField>(find.byKey(const Key('robot-port'))).controller!.text, '9090',
        reason: 'each mode keeps its own value in the second field');
  });

  testWidgets('a recent robot remembers its mode and port and connects in one tap', (tester) async {
    // Saved by an older version: a bare rosbridge address.
    SharedPreferences.setMockInitialValues({'robot_ip_history': ['192.168.1.12']});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('rosbridge'), findsOneWidget, reason: 'the address is the title, not repeated below it');
    expect(find.byKey(const Key('robot-host')), findsNothing, reason: 'the form for a new robot stays folded');
    await tester.tap(find.byKey(const Key('recent-rosbridge-192.168.1.12-9090')));
    await tester.pump();
    expect(find.descendant(of: find.byKey(const Key('recent-rosbridge-192.168.1.12-9090')),
        matching: find.byType(CircularProgressIndicator)), findsOneWidget, reason: 'one tap connects');
    await tester.ensureVisible(find.text('Cancel connection'));
    await tester.tap(find.text('Cancel connection'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 9)); // let the abandoned socket's connect timeout run out
  });

  testWidgets('with saved robots, Add a robot opens the form and Cancel folds it again', (tester) async {
    SharedPreferences.setMockInitialValues({'recent_robots': ['{"mode":"rosbridge","host":"10.0.0.5","port":"9090"}']});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Connect to your robot'), findsNothing, reason: 'the saved robots are the screen');
    expect(find.byKey(const Key('robot-host')), findsNothing);
    await tester.tap(find.byKey(const Key('add-robot')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-host')), findsOneWidget);
    expect(find.byKey(const Key('add-robot')), findsNothing);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('robot-host')), findsNothing);
  });

  testWidgets('forgetting a recent robot removes it', (tester) async {
    SharedPreferences.setMockInitialValues({'recent_robots': [
      '{"mode":"direct","host":"","port":"0"}', '{"mode":"rosbridge","host":"10.0.0.5","port":"9091"}']});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.text('Any robot on this Wi-Fi'), findsOneWidget);
    expect(find.text('rosbridge :9091'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byKey(const Key('recent-rosbridge-10.0.0.5-9091')), matching: find.byTooltip('Robot options')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();
    expect(find.text('rosbridge :9091'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('recent_robots'), hasLength(1));
  });

  testWidgets('connection page fits a narrow screen with enlarged text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)),
      child: const ConnectPage(),
    ))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('connect-button')), findsOneWidget);
  });

  test('recent history caps at five and distinguishes ports while retaining identity', () async {
    final prefs = await SharedPreferences.getInstance();
    for (var port = 9090; port < 9097; port++) {
      await RecentRobot.save(prefs, RecentRobot(ConnectMode.rosbridge, 'robot', '$port'));
    }
    final saved = RecentRobot.load(prefs);
    expect(saved, hasLength(5));
    expect(saved.first.portOrDomain, '9096');
    expect(saved.last.portOrDomain, '9092');
    await RecentRobot.update(prefs, saved.last, name: 'Lab robot', robotType: 'TurtleBot3');
    await RecentRobot.save(prefs, RecentRobot(ConnectMode.rosbridge, 'robot', '9092'));
    expect(RecentRobot.load(prefs).first.name, 'Lab robot');
    expect(RecentRobot.load(prefs).first.robotType, 'TurtleBot3');
    await RecentRobot.remove(prefs, saved.last);
    await RecentRobot.update(prefs, saved.last, robotType: 'Late discovery');
    expect(RecentRobot.load(prefs).where(saved.last.same), isEmpty);
  });

  testWidgets('recent robots collapse to three and a name can be edited', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    for (var i = 0; i < 5; i++) {
      await RecentRobot.save(prefs, RecentRobot(ConnectMode.rosbridge, 'robot$i', '9090', robotType: 'TurtleBot3'));
    }
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();
    expect(find.byTooltip('Robot options'), findsNWidgets(3));
    await tester.ensureVisible(find.byKey(const Key('recent-expand')));
    await tester.tap(find.byKey(const Key('recent-expand')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Robot options'), findsNWidgets(5));
    final menu = find.descendant(of: find.byKey(const Key('recent-rosbridge-robot4-9090')),
      matching: find.byTooltip('Robot options'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('recent-name')), 'Warehouse robot');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Warehouse robot'), findsOneWidget);
    expect(RecentRobot.load(prefs).first.name, 'Warehouse robot');
    expect(tester.takeException(), isNull);
  });
}
