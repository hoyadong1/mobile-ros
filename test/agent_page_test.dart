import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/audit_log.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/agent_page.dart';
import 'package:ros_tester/navigation_goal.dart' show RosVersion;
import 'package:ros_tester/robot_profile.dart';
import 'package:ros_tester/robot_session.dart';
import 'support/fake_ros_connection.dart';

class Scripted extends AgentBackend {
  Scripted(this.reply, this.calls);
  final String reply;
  final List<SkillCall> calls;
  @override
  String get name => 'scripted';
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: calls, reply: reply);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(FakeConnection, RobotSession, AuditLog)> open(WidgetTester tester,
      {AgentBackend Function(AgentSettings)? backend}) async {
    final robot = FakeConnection();
    final session = RobotSession(connection: robot, ip: 'robot', port: '9090');
    session.drive.configure(RobotProfile.defaults(DriveType.differential), RosVersion.ros2);
    final log = AuditLog();
    addTearDown(() {
      session.dispose();
      log.dispose();
    });
    await tester.pumpWidget(MaterialApp(home: AgentPage(session: session, log: log, backendFactory: backend,
        localModel: () async => null)));
    await tester.pumpAndSettle();
    return (robot, session, log);
  }

  testWidgets('without a proxy the page asks for setup and saves the address', (tester) async {
    await open(tester);
    expect(find.byKey(const Key('agent-setup')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const Key('agent-input'))).enabled, isFalse);

    await tester.tap(find.byKey(const Key('agent-setup')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('agent-proxy-url')), 'http://192.168.0.29:8787/v1/plan');
    await tester.enterText(find.byKey(const Key('agent-proxy-token')), 'secret');
    await tester.tap(find.byKey(const Key('agent-settings-save')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agent-setup')), findsNothing);
    expect(tester.widget<TextField>(find.byKey(const Key('agent-input'))).enabled, isTrue);
    final saved = await AgentSettings.load();
    expect((saved.proxyUrl, saved.token), ('http://192.168.0.29:8787/v1/plan', 'secret'));
  });

  testWidgets('suggestions and the "can do" list fit this robot', (tester) async {
    await open(tester, backend: (_) => Scripted('ok', const []));
    await tester.pump();
    expect(find.text('Move forward 0.5 meters'), findsOneWidget);
    expect(find.text('Turn left 90 degrees'), findsOneWidget);
    expect(find.text('Is anything wrong with the robot?'), findsOneWidget,
        reason: 'check_robot is offered; this robot has no battery topic, so not a battery question');
    expect(find.text('Go to (1.0, 0.5)'), findsNothing, reason: 'no map navigation here');
    expect(find.byKey(const Key('agent-abilities')), findsOneWidget);
    expect(find.text('Check the robot'), findsOneWidget);
    expect(find.text('Go to a saved place'), findsNothing);
  });

  testWidgets('an instruction shows the reply, the step and its result; STOP stops the base', (tester) async {
    final (robot, _, log) = await open(tester,
        backend: (_) => Scripted('상태를 확인할게요.', const [SkillCall('get_status')]));
    await tester.enterText(find.byKey(const Key('agent-input')), '지금 상태 알려줘');
    await tester.pump(); // the send button turns on once there is text
    await tester.tap(find.byKey(const Key('agent-send')));
    await tester.pumpAndSettle();

    expect(find.text('지금 상태 알려줘'), findsOneWidget);
    expect(find.text('상태를 확인할게요.'), findsOneWidget);
    expect(find.text('get_status()'), findsOneWidget);
    expect(find.textContaining('The robot is not moving'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-stop')));
    await tester.pumpAndSettle();
    expect(robot.sent.lastWhere((m) => m['op'] == 'publish')['msg']['linear']['x'], 0);
    expect(log.entries.last.text, 'Stopped.');
  });

  testWidgets('example chips send their instruction', (tester) async {
    final (_, _, log) = await open(tester, backend: (_) => Scripted('네.', const []));
    await tester.tap(find.text(AgentPageState.examples.first));
    await tester.pumpAndSettle();
    expect(log.entries.first.text, AgentPageState.examples.first);
  });
}
