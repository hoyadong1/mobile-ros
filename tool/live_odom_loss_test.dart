// ignore_for_file: avoid_print
// Inject only incoming odometry loss; keep Gazebo, commands and other ROS traffic live.
// Run through scripts/dev-env/sim_live_test.sh to start with a fresh robot pose.
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ros_tester/agent/agent.dart';
import 'package:ros_tester/agent/skill.dart';
import 'package:ros_tester/controllers/odometry.dart';
import 'package:ros_tester/robot_session.dart';
import 'package:ros_tester/ros_client.dart';
import 'package:ros_tester/ros_connection.dart';

class OdomLossConnection implements RosConnection {
  OdomLossConnection(this.inner);
  final RosConnection inner;
  String? blockedTopic;
  int dropped = 0;
  @override
  Stream<Map<String, dynamic>> get messages => inner.messages.where((event) {
    if (event['op'] == 'publish' && event['topic'] == blockedTopic) {
      dropped++;
      return false;
    }
    return true;
  });
  @override
  bool get isClosed => inner.isClosed;
  @override
  String? get lastError => inner.lastError;
  @override
  Duration get timeout => inner.timeout;
  @override
  Future<void> get ready => inner.ready;
  @override
  void send(Map<String, dynamic> message) => inner.send(message);
  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) => inner.call(service, args);
  @override
  void close() => inner.close();
}

class MoveBackend extends AgentBackend {
  @override
  String get name => 'scripted odometry failure';
  double distance = 1;
  @override
  Future<AgentPlan> plan(AgentRequest request) async => AgentPlan(calls: [SkillCall('move', {'distance_m': distance})]);
}

void main() {
  test('odometry loss stops real simulated motion and restored data permits another move', () async {
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    const host = String.fromEnvironment('ROBOT_HOST', defaultValue: '127.0.0.1');
    const port = String.fromEnvironment('ROBOT_PORT', defaultValue: '9090');
    final link = OdomLossConnection(RosConnection(host, port));
    addTearDown(link.close);
    await link.ready;
    final session = RobotSession(connection: link, ip: host, port: port);
    addTearDown(session.dispose);
    await session.prepare();
    expect(await session.odometry.waitFresh(), isTrue);
    final observerLink = RosConnection(host, port);
    addTearDown(observerLink.close);
    await observerLink.ready;
    final observerRos = RosClient(observerLink);
    addTearDown(observerRos.dispose);
    final observer = Odometry(observerRos)..listen(session.odometry.topic!);
    addTearDown(observer.dispose);
    expect(await observer.waitFresh(), isTrue);
    final backend = MoveBackend();
    final agent = RobotAgent.forSession(session, backend);
    addTearDown(agent.stop);
    final start = observer.pose!;
    final running = agent.handle('move one metre');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final cutPose = observer.pose!;
    expect(math.sqrt(math.pow(cutPose.x-start.x, 2)+math.pow(cutPose.y-start.y, 2)), greaterThan(0.02));
    link.blockedTopic = session.odometry.topic;
    final watch = Stopwatch()..start();
    final result = await running.timeout(const Duration(seconds: 4));
    watch.stop();
    expect(result.ok, isFalse);
    expect(result.results.last.message, contains('odometry stopped arriving'));
    expect(watch.elapsedMilliseconds, lessThan(2000));
    expect(link.dropped, greaterThan(0));
    expect(link.isClosed, isFalse, reason: 'selective odometry loss, not a disconnected robot');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(observer.isFresh(), isTrue);
    final stopped = observer.pose!;
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(observer.isFresh(), isTrue);
    final after = observer.pose!;
    final drift = math.sqrt(math.pow(after.x-stopped.x, 2)+math.pow(after.y-stopped.y, 2));
    print('  odometry loss: stopped in ${watch.elapsedMilliseconds} ms; stationary drift ${drift.toStringAsFixed(4)} m; dropped ${link.dropped} samples');
    expect(drift, lessThan(0.02), reason: 'independent observer confirms Gazebo robot stopped');
    link.blockedTopic = null;
    expect(await session.odometry.waitFresh(), isTrue);
    backend.distance = 0.15;
    final recovered = await agent.handle('move 15 centimetres').timeout(const Duration(seconds: 8));
    print('  restored odometry: ${recovered.results.lastOrNull}');
    expect(recovered.ok, isTrue);
  }, timeout: const Timeout(Duration(minutes: 1)));
}
