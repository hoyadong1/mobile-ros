import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/mini_map.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fake_ros_connection.dart';

Future<FakeConnection> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
    'topics': ['/cmd_vel', '/odom'], 'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry']};
  await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: Center(
    child: FilledButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute<bool>(
        builder: (_) => MainPage(ip: 'robot', port: '9090', connection: robot))),
      child: const Text('open')),
  )))));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return robot;
}

void main() {
  testWidgets('tablet home uses a map pane, adapts on rotation and collapses after disconnect', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final robot = FakeConnection()..serviceResponses['/rosapi/topics'] = {
      'topics': ['/cmd_vel', '/odom', '/map'],
      'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'nav_msgs/msg/OccupancyGrid']};
    await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(2)), child: child!),
      home: MainPage(ip: 'robot', port: '9090', connection: robot)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-wide')), findsOneWidget);
    final mapState = tester.state<MiniMapState>(find.byType(MiniMap));
    int mapSubscriptions() => robot.sent.where((m) => m['op'] == 'subscribe' && m['topic'] == '/map').length;
    final subscribed = mapSubscriptions();
    expect(tester.getTopLeft(find.byType(MiniMap)).dx,
        greaterThan(tester.getTopLeft(find.byKey(const Key('tool-control'))).dx));
    final labelFinder = find.text('AI & routines');
    final label = tester.widget<Text>(labelFinder);
    final measured = TextPainter(text: TextSpan(text: label.data, style: label.style),
      textDirection: TextDirection.ltr, textScaler: TextScaler.linear(2))
      ..layout(maxWidth: tester.getSize(labelFinder).width);
    expect(tester.getSize(labelFinder).height, greaterThanOrEqualTo(measured.height),
      reason: 'the whole label must fit, including its second line at 200% text');
    measured.dispose();
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(800, 1280));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-wide')), findsNothing);
    expect(find.byKey(const Key('home-stacked')), findsOneWidget);
    expect(identical(tester.state<MiniMapState>(find.byType(MiniMap)), mapState), isTrue,
      reason: 'rotation keeps the map image, TF and pose instead of waiting for new latched data');
    expect(mapSubscriptions(), subscribed, reason: 'rotation must not restart map subscriptions');
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-wide')), findsOneWidget);
    expect(identical(tester.state<MiniMapState>(find.byType(MiniMap)), mapState), isTrue);
    robot.close();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('home-wide')), findsNothing);
    expect(find.byType(MiniMap), findsNothing);
    expect(find.byKey(const Key('reconnect')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a wide home without a map keeps its tools centred without an empty map pane', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester);
    expect(find.byKey(const Key('home-wide')), findsNothing);
    final bounds = tester.getRect(find.byKey(const Key('home-stacked')));
    expect(bounds.width, lessThanOrEqualTo(808));
    expect(bounds.center.dx, closeTo(640, 1));
    expect(find.byType(MiniMap), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('discovered robot identity is reported for the recent connection label', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/topics'] = {
        'topics': ['/cmd_vel', '/odom'], 'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry']}
      ..serviceResponses['/rosapi/nodes'] = {'nodes': ['/turtlebot3_diff_drive']};
    final identities = <String>[];
    await tester.pumpWidget(MaterialApp(home: MainPage(ip: 'robot', port: '9090', connection: robot,
      onRobotIdentified: identities.add)));
    await tester.pumpAndSettle();
    expect(identities, ['TurtleBot3']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the main tools come first; back asks before disconnecting', (tester) async {
    final robot = await _open(tester);
    expect(find.text('Connected'), findsOneWidget);
    expect(find.byKey(const Key('stop-all')), findsOneWidget, reason: 'STOP is always on the home screen');
    expect(tester.getTopLeft(find.byKey(const Key('tool-control'))).dy,
        lessThan(tester.getTopLeft(find.text('More')).dy), reason: 'the main tools come before the rest');
    expect(find.text('This robot'), findsNothing, reason: 'its details are in About this robot');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('leave-dialog')), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.text('Connected'), findsOneWidget);
    expect(robot.isClosed, isFalse);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
    expect(robot.isClosed, isTrue);
  });

  testWidgets('once the link is gone, back leaves without asking and Reconnect is offered', (tester) async {
    final robot = await _open(tester);
    robot.close();
    await tester.pumpAndSettle();
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.byKey(const Key('reconnect')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('leave-dialog')), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
