// On-device check that a direct ROS 2 (DDS) connection notices a lost robot by itself.
// The test prints CUT_NOW once odometry flows; the host then freezes the simulation
// (`kill -STOP` on its ROS processes), and the connection must close within a few seconds.
//   flutter test integration_test/direct_link_loss_test.dart -d <device> --dart-define=ROBOT=<pc ip>
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ros_tester/dds/direct_connection.dart';

const robot = String.fromEnvironment('ROBOT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a direct connection closes by itself when the robot goes silent', (tester) async {
    final session = await DirectRosSession.open(robot: robot, domain: 0, discoveryTimeout: const Duration(seconds: 12));
    final ros = session.connect(ownsSession: true);
    final closed = Completer<DateTime>();
    var samples = 0;
    ros.messages.listen((m) {
      if (m['topic'] == '/odom') samples++;
    }, onDone: () => closed.complete(DateTime.now()));
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    ros.send({'op': 'subscribe', 'topic': '/scan'});
    while (samples < 30) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(session.closed, isFalse, reason: 'steady data must not look like a lost link');
    debugPrint('CUT_NOW');
    final cutAt = DateTime.now();
    final at = await closed.future.timeout(const Duration(seconds: 40));
    debugPrint('LOST after ${at.difference(cutAt).inMilliseconds} ms (includes the host reacting to CUT_NOW): '
        '${session.lostReason}');
    expect(session.lostReason, startsWith('Lost contact with the robot'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
