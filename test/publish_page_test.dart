import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/publish_page.dart';

import 'support/fake_ros_connection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProvider,
          (call) async => Directory.systemTemp.path,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
  });

  FakeConnection robotWithTopics() => FakeConnection()
    ..serviceResponses['/rosapi/topics'] = {
      'topics': ['/counter'],
      'types': ['demo/msg/Counter'],
    }
    ..serviceResponses['/rosapi/interfaces'] = {
      'interfaces': ['demo/msg/Counter', 'demo/srv/Reset', 'demo/msg/Extra'],
    }
    ..serviceResponses['/rosapi/message_details'] = {
      'typedefs': [
        {
          'type': 'demo/Counter',
          'fieldnames': ['count', 'enabled'],
          'fieldtypes': ['int32', 'bool'],
          'fieldarraylen': [-1, -1],
          'examples': ['7', 'false'],
          'constnames': [],
          'constvalues': [],
        },
      ],
    };

  FakeConnection twistRobot() => FakeConnection()
    ..serviceResponses['/rosapi/topics'] = {
      'topics': ['/cmd_vel'],
      'types': ['geometry_msgs/msg/Twist'],
    }
    ..serviceResponses['/rosapi/interfaces'] = {
      'interfaces': ['geometry_msgs/msg/Twist'],
    }
    ..serviceResponses['/rosapi/message_details'] = {
      'typedefs': [
        {
          'type': 'geometry_msgs/Twist',
          'fieldnames': ['linear', 'angular'],
          'fieldtypes': ['geometry_msgs/Vector3', 'geometry_msgs/Vector3'],
          'fieldarraylen': [-1, -1],
          'examples': ['{}', '{}'],
          'constnames': [],
          'constvalues': [],
        },
        {
          'type': 'geometry_msgs/Vector3',
          'fieldnames': ['x', 'y', 'z'],
          'fieldtypes': ['float64', 'float64', 'float64'],
          'fieldarraylen': [-1, -1, -1],
          'examples': ['0.0', '0.0', '0.0'],
          'constnames': [],
          'constvalues': [],
        },
      ],
    };

  Future<FakeConnection> open(WidgetTester tester) async {
    final robot = robotWithTopics();
    await tester.pumpWidget(
      MaterialApp(
        home: PublishPage(
          ip: 'robot.local',
          port: '9090',
          connectionFactory: (_, _) => robot,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return robot;
  }

  testWidgets(
    'discovers topics and message schema, then publishes typed defaults',
    (tester) async {
      final robot = await open(tester);

      await tester.tap(find.byKey(const Key('publish-topic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/counter').last);
      await tester.pumpAndSettle();

      expect(find.text('demo/msg/Counter'), findsWidgets);
      expect(find.text('count  ·  int32'), findsOneWidget);
      expect(find.text('enabled  ·  bool'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('publish-once')));
      await tester.tap(find.byKey(const Key('publish-once')));
      await tester.pumpAndSettle();

      expect(
        robot.sent,
        contains(
          predicate<Map>(
            (message) =>
                message['op'] == 'advertise' &&
                message['topic'] == '/counter' &&
                message['type'] == 'demo/msg/Counter',
          ),
        ),
      );
      expect(
        robot.sent,
        contains(
          predicate<Map>(
            (message) =>
                message['op'] == 'publish' &&
                message['topic'] == '/counter' &&
                (message['msg'] as Map)['count'] == 7 &&
                (message['msg'] as Map)['enabled'] == false,
          ),
        ),
      );
      expect(find.textContaining('delivery is not confirmed'), findsOneWidget);
    },
  );

  testWidgets(
    'JSON mode validates against the discovered schema before publishing',
    (tester) async {
      final robot = await open(tester);
      await tester.tap(find.byKey(const Key('publish-topic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/counter').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('JSON'));
      await tester.tap(find.text('JSON'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('publish-json')),
        '{"count": 12, "enabled": true}',
      );
      await tester.ensureVisible(find.byKey(const Key('publish-once')));
      await tester.tap(find.byKey(const Key('publish-once')));
      await tester.pumpAndSettle();

      expect(
        robot.sent,
        contains(
          predicate<Map>(
            (message) =>
                message['op'] == 'publish' &&
                (message['msg'] as Map)['count'] == 12 &&
                (message['msg'] as Map)['enabled'] == true,
          ),
        ),
      );
    },
  );

  testWidgets(
    'repeated Twist publish stops with a zero command and unadvertises',
    (tester) async {
      final robot = twistRobot();
      await tester.pumpWidget(
        MaterialApp(
          home: PublishPage(
            ip: 'robot.local',
            port: '9090',
            connectionFactory: (_, _) => robot,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('publish-topic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/cmd_vel').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('publish-repeat')));
      await tester.tap(find.byKey(const Key('publish-repeat')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.tap(find.byKey(const Key('publish-stop')));
      await tester.pump();

      final publishes = robot.sent
          .where((message) => message['op'] == 'publish')
          .toList();
      expect(publishes.length, greaterThanOrEqualTo(3));
      expect(publishes.last['msg'], {
        'linear': {'x': 0, 'y': 0, 'z': 0},
        'angular': {'x': 0, 'y': 0, 'z': 0},
      });
      expect(
        robot.sent,
        contains(
          predicate<Map>(
            (message) =>
                message['op'] == 'unadvertise' &&
                message['topic'] == '/cmd_vel',
          ),
        ),
      );
    },
  );

  testWidgets(
    'leaving after a Twist publish sends zero velocity and releases the publisher',
    (tester) async {
      final robot = twistRobot();
      await tester.pumpWidget(
        MaterialApp(
          home: PublishPage(
            ip: 'robot.local',
            port: '9090',
            connectionFactory: (_, _) => robot,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('publish-topic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('/cmd_vel').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('publish-once')));
      await tester.tap(find.byKey(const Key('publish-once')));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

      final publishes = robot.sent
          .where((message) => message['op'] == 'publish')
          .toList();
      expect(publishes, hasLength(2));
      expect(publishes.last['msg'], {
        'linear': {'x': 0, 'y': 0, 'z': 0},
        'angular': {'x': 0, 'y': 0, 'z': 0},
      });
      expect(
        robot.sent,
        contains(
          predicate<Map>(
            (message) =>
                message['op'] == 'unadvertise' &&
                message['topic'] == '/cmd_vel',
          ),
        ),
      );
    },
  );
}
