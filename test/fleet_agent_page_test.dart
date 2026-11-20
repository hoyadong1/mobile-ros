import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/fleet_agent_page.dart';
import 'package:ros_tester/robot_session.dart';

import 'support/fake_ros_connection.dart';

void main() {
  testWidgets('setting the fleet assistant address keeps on-device-only mode', (tester) async {
    SharedPreferences.setMockInitialValues({'agent_on_device_only': true});
    final connection = FakeConnection();
    final sessions = [for (final name in ['robot1', 'robot2'])
      RobotSession(connection: connection, ip: 'robot', port: '9090', namespace: '/$name')];
    await tester.pumpWidget(MaterialApp(home: FleetAgentPage(sessions: sessions)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Assistant connection'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Proxy URL'), 'http://127.0.0.1:8787/v1/plan');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_proxy_url'), 'http://127.0.0.1:8787/v1/plan');
    expect(prefs.getBool('agent_on_device_only'), isTrue, reason: 'requests must not start going online');
    // Without a downloaded model and with online use turned off, there is no assistant to send to.
    expect(find.textContaining('Download the on-device model'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    for (final s in sessions) { s.dispose(); }
    connection.close();
  });
}
