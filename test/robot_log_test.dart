import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:ros_tester/log_page.dart';
import 'package:ros_tester/robot_log.dart';
import 'package:ros_tester/ros_client.dart';

import 'support/fake_ros_connection.dart';

Map<String, dynamic> _ros2(String node, String text, {int level = 20, int sec = 1700000000}) => {
  'op': 'publish', 'topic': '/rosout',
  'msg': {'stamp': {'sec': sec, 'nanosec': 0}, 'level': level, 'name': node, 'msg': text,
    'file': 'amcl.cpp', 'function': 'laserReceived', 'line': 42},
};

void main() {
  group('LogEntry', () {
    test('reads ROS 2 and ROS 1 log messages, and both kinds of level', () {
      final two = LogEntry.parse(_ros2('amcl', 'Received a scan', level: 30)['msg'] as Map)!;
      expect(two.level, LogLevel.warn);
      expect(two.node, 'amcl');
      expect(two.time, DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(two.line, 42);
      final one = LogEntry.parse({'header': {'stamp': {'secs': 1700000001, 'nsecs': 0}}, 'level': 8,
        'name': '/move_base', 'msg': 'Aborting  \n'})!;
      expect(one.level, LogLevel.error);
      expect(one.node, 'move_base', reason: 'leading slash dropped');
      expect(one.text, 'Aborting');
      expect([1, 2, 4, 8, 16, 10, 20, 30, 40, 50].map(logLevelOf), [
        LogLevel.debug, LogLevel.info, LogLevel.warn, LogLevel.error, LogLevel.fatal,
        LogLevel.debug, LogLevel.info, LogLevel.warn, LogLevel.error, LogLevel.fatal]);
      expect(LogEntry.parse({'level': 20}), isNull);
    });
  });

  group('RobotLog', () {
    late FakeConnection robot;
    late RobotLog log;
    setUp(() {
      robot = FakeConnection();
      log = RobotLog(RosClient(robot), capacity: 5)..start();
    });
    tearDown(() { log.dispose(); robot.close(); });

    test('subscribes to /rosout, newest first, repeats folded and moved to the top', () async {
      expect(robot.sent.where((m) => m['op'] == 'subscribe').map((m) => m['topic']), ['/rosout']);
      robot.events
        ..add(_ros2('amcl', 'one'))
        ..add(_ros2('bt_navigator', 'two'))
        ..add(_ros2('amcl', 'one', sec: 1700000005));
      await Future<void>.delayed(Duration.zero);
      expect(log.entries.map((e) => e.text), ['one', 'two']);
      expect(log.entries.first.count, 2);
      expect(log.entries.first.time, DateTime.fromMillisecondsSinceEpoch(1700000005000));
      expect(log.nodes, ['amcl', 'bt_navigator']);
    });

    test('lines that differ only in numbers are one repeating line, showing the latest', () async {
      robot.events
        ..add(_ros2('amcl', 'Message Filter dropping message: frame base_scan at time 958.780'))
        ..add(_ros2('amcl', 'Message Filter dropping message: frame base_scan at time 965.580', sec: 1700000003))
        ..add(_ros2('amcl', 'Message Filter dropping message: frame odom', sec: 1700000004));
      await Future<void>.delayed(Duration.zero);
      expect(log.entries, hasLength(2));
      expect(log.entries.last.count, 2);
      expect(log.entries.last.text, endsWith('965.580'));
    });

    test('counts problems not yet seen, keeps a bounded history', () async {
      for (var i = 0; i < 8; i++) {
        robot.events.add(_ros2('n', 'line ${String.fromCharCode(97 + i)}', level: i.isEven ? 40 : 20));
      }
      await Future<void>.delayed(Duration.zero);
      expect(log.entries, hasLength(5));
      expect(log.unseenProblems, 4);
      log.markSeen();
      expect(log.unseenProblems, 0);
      expect(log.problems.errors, 2, reason: 'lines 4 and 6 of the five kept (3..7)');
    });

    test('filters by level, node and text', () {
      final e = LogEntry(level: LogLevel.warn, node: 'amcl', text: 'No laser scan received', time: DateTime(2026));
      expect(logFilterMatches(LogFilter.warnings, e), isTrue);
      expect(logFilterMatches(LogFilter.errors, e), isFalse);
      expect(logFilterMatches(LogFilter.all, e, node: 'other'), isFalse);
      expect(logFilterMatches(LogFilter.all, e, query: 'LASER'), isTrue);
      expect(logFilterMatches(LogFilter.all, e, query: 'battery'), isFalse);
    });
  });

  testWidgets('log screen: problems first when there are new ones, details, pause, copy', (tester) async {
    final robot = FakeConnection();
    final log = RobotLog(RosClient(robot))..start();
    addTearDown(() { log.dispose(); robot.close(); });
    robot.events
      ..add(_ros2('controller_server', 'Received a goal, begin computing control effort.'))
      ..add(_ros2('amcl', 'AMCL cannot publish a pose or update the transform. Please set the initial pose...', level: 30))
      ..add(_ros2('amcl', 'AMCL cannot publish a pose or update the transform. Please set the initial pose...', level: 30))
      ..add(_ros2('planner_server', 'GridBased: failed to create plan, no valid path found.', level: 40));
    await tester.pump(const Duration(milliseconds: 300));
    expect(log.unseenProblems, 2);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(MaterialApp(home: RobotLogPage(log: log)));
    await tester.pump();
    expect(log.unseenProblems, 0, reason: 'opening the log marks them seen');
    expect(find.text('Problems 2'), findsOneWidget);
    expect(find.textContaining('Received a goal'), findsNothing, reason: 'opens on problems when there are new ones');
    expect(find.textContaining('failed to create plan'), findsOneWidget);
    expect(find.text('×2'), findsOneWidget, reason: 'the repeated warning is folded');

    await tester.tap(find.text('All'));
    await tester.pump();
    expect(find.textContaining('Received a goal'), findsOneWidget);

    await tester.tap(find.textContaining('failed to create plan'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('log-detail-text')), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('[Error] planner_server: GridBased: failed'));

    await tester.tap(find.byKey(const Key('log-pause')));
    await tester.pump();
    robot.events.add(_ros2('bt_navigator', 'Goal succeeded'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Goal succeeded'), findsNothing, reason: 'paused');
    expect(find.text('Paused · 1 new'), findsOneWidget);
    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(find.textContaining('Goal succeeded'), findsOneWidget);

    await tester.tap(find.text('Errors 1'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('log-search-toggle')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('log-search')), 'battery');
    await tester.pump();
    expect(find.text('Nothing matches'), findsOneWidget);
  });

  testWidgets('a quiet robot: says it is listening', (tester) async {
    final robot = FakeConnection();
    final log = RobotLog(RosClient(robot))..start();
    addTearDown(() { log.dispose(); robot.close(); });
    await tester.pumpWidget(MaterialApp(home: RobotLogPage(log: log)));
    expect(find.text('Listening for log messages…'), findsOneWidget);
  });
}
