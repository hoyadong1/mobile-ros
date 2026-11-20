// Re-subscribing to a topic after another page closed its subscription (direct ROS 2 connection).
//   flutter test integration_test/direct_resubscribe_test.dart -d <device> --dart-define=ROBOT=<pc ip>
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ros_tester/dds/direct_connection.dart';
import 'package:ros_tester/ros_connection.dart';

const robot = String.fromEnvironment('ROBOT');

Future<bool> receives(RosConnection ros, String topic) => ros.messages
    .firstWhere((m) => m['op'] == 'publish' && m['topic'] == topic)
    .timeout(const Duration(seconds: 5))
    .then((_) => true, onError: (_) => false);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a topic can be subscribed again after a page closed it', (
    tester,
  ) async {
    final session = await DirectRosSession.open(robot: robot, domain: 0);
    final root = session.connect(ownsSession: true);
    addTearDown(root.close);
    final results = <String, bool>{};
    for (final topic in ['/odom', '/scan']) {
      final first = session.connect();
      first.send({'op': 'subscribe', 'topic': topic});
      results['$topic first page'] = await receives(first, topic);
      first.close();
      final second = session.connect();
      second.send({'op': 'subscribe', 'topic': topic, 'throttle_rate': 100});
      results['$topic second page'] = await receives(second, topic);
      second.send({'op': 'unsubscribe', 'topic': topic});
      second.send({'op': 'subscribe', 'topic': topic});
      results['$topic same page again'] = await receives(second, topic);
      second.close();
    }
    debugPrint('resubscribe: $results');
    expect(results.values, everyElement(isTrue));
  });
}
