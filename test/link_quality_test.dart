import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/link_quality.dart';
import 'package:ros_tester/ros_client.dart';

import 'support/fake_ros_connection.dart';

void main() {
  test('the round trip is measured, and a robot without rosapi is left alone', () async {
    var now = DateTime(2026, 11, 19, 10);
    var answer = () async => <String, dynamic>{};
    final link = LinkQuality(RosClient(FakeConnection()), every: const Duration(hours: 1), clock: () => now,
        probe: () async {
          now = now.add(const Duration(milliseconds: 420)); // the answer comes back 420 ms later
          return answer();
        });
    addTearDown(link.dispose);
    expect(link.lagMs, isNull);
    await link.measure();
    expect(link.lagMs, 420);
    expect(link.lagMs! >= LinkQuality.slowMs && link.lagMs! < LinkQuality.verySlowMs, isTrue, reason: 'shown, as slow');

    // Once measured, a request that never answers counts as the longest lag, not as "fine".
    answer = () async => throw TimeoutException('no answer');
    await link.measure();
    expect(link.lagMs, link.timeout.inMilliseconds);
  });

  test('no answer from the start: nothing shown', () async {
    final link = LinkQuality(RosClient(FakeConnection()), every: const Duration(hours: 1),
        probe: () async => throw StateError('no rosapi'));
    addTearDown(link.dispose);
    for (var i = 0; i < 3; i++) {
      await link.measure();
    }
    expect(link.lagMs, isNull);
  });
}
