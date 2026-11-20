// Off-screen pictures of the robot-memory and fleet screens on a phone and tablets, for review:
//   FLUTTER_ROOT=<flutter sdk> flutter test tool/memory_ui_review_test.dart   -> build/memory-ui/*.png
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/learned_tools.dart';
import 'package:ros_tester/agent/learning.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent/fleet_agent.dart';
import 'package:ros_tester/app_theme.dart';
import 'package:ros_tester/fleet_agent_page.dart';
import 'package:ros_tester/main_page.dart';
import 'package:ros_tester/memory.dart';
import 'package:ros_tester/robot_memory_page.dart';
import 'package:ros_tester/robot_persona.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/routines.dart';
import 'package:ros_tester/widgets/robot_intro.dart';
import '../test/support/fake_ros_connection.dart';

FakeConnection fleet() => FakeConnection()..serviceResponses['/rosapi/topics'] = {
  'topics': ['/robot1/cmd_vel', '/robot1/odom', '/robot1/scan', '/robot2/cmd_vel', '/robot2/odom', '/robot2/scan'],
  'types': ['geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/LaserScan',
    'geometry_msgs/msg/Twist', 'nav_msgs/msg/Odometry', 'sensor_msgs/msg/LaserScan'],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) throw StateError('Set FLUTTER_ROOT to capture readable UI review images.');
    for (final font in [('Roboto', 'roboto-regular.ttf'), ('MaterialIcons', 'materialicons-regular.otf')]) {
      final loader = FontLoader(font.$1)..addFont(
        File('$root/bin/cache/artifacts/material_fonts/${font.$2}').readAsBytes()
          .then((data) => ByteData.sublistView(data)));
      await loader.load();
    }
  });
  for (final (size, scale, brightness) in [
    (const Size(390, 844), 1.0, Brightness.light),
    (const Size(390, 844), 2.0, Brightness.light),
    (const Size(390, 844), 1.0, Brightness.dark),
    (const Size(800, 1280), 1.0, Brightness.light),
    (const Size(1280, 800), 1.0, Brightness.light),
  ]) {
    testWidgets('memory and fleet screens $size ${scale}x ${brightness.name}', (tester) async {
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      // ignore: invalid_use_of_visible_for_testing_member
      Memory.user.unload();
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const capture = Key('capture');
      final base = buildTheme(brightness);
      final theme = base.copyWith(textTheme: base.textTheme.apply(fontFamily: 'Roboto'),
        appBarTheme: base.appBarTheme.copyWith(titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto')),
        listTileTheme: base.listTileTheme.copyWith(
          titleTextStyle: base.listTileTheme.titleTextStyle?.copyWith(fontFamily: 'Roboto'),
          subtitleTextStyle: base.listTileTheme.subtitleTextStyle?.copyWith(fontFamily: 'Roboto')),
        chipTheme: base.chipTheme.copyWith(labelStyle: base.chipTheme.labelStyle?.copyWith(fontFamily: 'Roboto')));
      Widget frame(Widget page) => MaterialApp(theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: RepaintBoundary(key: capture, child: child)), home: page);
      final prefix = '${size.width.toInt()}x${size.height.toInt()}-${scale.toInt()}x-${brightness.name}';
      final problems = <String>[];
      Future<void> save(String page) async {
        final e = tester.takeException();
        if (e != null) problems.add('$page: $e');
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final dir = Directory('build/memory-ui');
          await dir.create(recursive: true);
          await File('${dir.path}/$prefix-$page.png').writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      // The workspace with two robots: the intro card at the top.
      final link = fleet();
      await tester.pumpWidget(frame(MainPage(ip: 'warehouse', port: '9090', connection: link)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      await save('workspace-intro');

      // The first meeting, half way.
      final s1 = RobotSession(connection: link, ip: 'warehouse', port: '9090', namespace: '/robot1');
      await tester.pumpWidget(frame(Scaffold(body: Builder(builder: (context) => Center(child: FilledButton(
          onPressed: () => RobotIntroSheet.open(context, s1), child: const Text('open')))))));
      await tester.tap(find.text('open'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('intro-choice-That\'s right')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('robot-intro-input')), '순돌이');
      await tester.tap(find.byKey(const Key('robot-intro-send')));
      await tester.pumpAndSettle();
      await save('intro-chat');
      await tester.tap(find.byKey(const Key('robot-intro-skip')));
      await tester.pumpAndSettle();
      await save('intro-role');
      Navigator.of(tester.element(find.byKey(const Key('robot-intro-chat')))).pop();
      await tester.pumpAndSettle();

      // The memory page with a bit of everything.
      final m = s1.memory;
      await m.setProfile(RobotPersona.roleKey, '창고 야간 순찰');
      await m.setProfile(RobotPersona.toneKey, 'Friendly');
      await Memory.user.setProfile(RobotPersona.callPersonKey, '민수');
      await m.add('note', '2층 계단 근처는 가지 마', pinned: true);
      await m.add('note', 'Charge before 6 pm every day, the dock is by the east door', source: 'assistant', pinned: true);
      for (final t in ['앞으로 20센티 가', '왼쪽으로 30도 돌고 오른쪽으로 30도 돌아', '입구로 가']) {
        await m.add('episode', '2026-11-18 09:1${t.length % 10} "$t" -> Moved 0.21 m forward.', source: 'app');
      }
      await LearnedTool.save(m, const LearnedTool(name: 'my_usual_1', description: 'd', origin: 'habit',
          steps: [SkillCall('rotate', {'angle_deg': 30}), SkillCall('rotate', {'angle_deg': -30})],
          phrases: ['왼쪽으로 30도 돌고 오른쪽으로 30도 돌아', '평소처럼 해']));
      await Memory.user.put(Learning.aliasKind, '거기', '부엌', pinned: true);
      final s2 = RobotSession(connection: link, ip: 'warehouse', port: '9090', namespace: '/robot2');
      await tester.pumpWidget(frame(RobotMemoryPage(session: s1, others: [s2])));
      await tester.pumpAndSettle();
      await save('memory-top');
      await tester.scrollUntilVisible(find.byKey(const Key('memory-learned')), 200);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('memory-learned')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('memory-tool-my_usual_1')), 200);
      await tester.pumpAndSettle();
      await save('memory-learned');

      // The fleet assistant with fleet routines.
      final book = FleetAgent.bookFor(s1);
      await book.load();
      await book.save(Routine(id: 'a', name: 'close up', steps: const [
        RoutineStep.call(SkillCall('move', {'robot': 'robot1', 'distance_m': 0.2})),
        RoutineStep.call(SkillCall('rotate', {'robot': 'robot2', 'angle_deg': 45})),
      ]));
      await book.save(Routine(id: 'b', name: 'morning patrol', steps: const [
        RoutineStep.call(SkillCall('move', {'robot': 'robot1', 'distance_m': 1})),
      ]));
      await tester.pumpWidget(frame(FleetAgentPage(sessions: [s1, s2])));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
      await save('fleet-assistant');

      await tester.pumpWidget(const SizedBox());
      s1.dispose();
      s2.dispose();
      book.dispose();
      link.close();
      expect(problems, isEmpty, reason: problems.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
