import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/direct_connection.dart';
import 'package:ros_tester/link_watch.dart';
import 'package:ros_tester/zenoh/zenoh_connection.dart';

import 'direct_connection_test.dart' show FakeDds;
import 'zenoh_connection_test.dart' show FakeZenoh, odomHash, tokens;
import 'dds_cdr_test.dart' show bundled;

void main() {
  group('LinkWatch', () {
    final t0 = DateTime(2026, 11, 14, 12);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    test('a steady stream that stops makes the link silent; a slow one never counts', () {
      final w = LinkWatch();
      for (var i = 0; i <= 10; i++) {
        w.sample('odom', at(i * 100)); // 10 Hz
      }
      for (var i = 0; i <= 3; i++) {
        w.sample('plan', at(i * 2000)); // 0.5 Hz: not steady
      }
      expect(w.silent(at(1000 + 1400)), isFalse, reason: 'within 1.5 s');
      expect(w.silent(at(1000 + 1600)), isTrue);
      expect(w.quietFor(at(2600)).inMilliseconds, 1600);
    });

    test('a burst on the log topic, then quiet, is not a lost link', () {
      final w = LinkWatch();
      for (var i = 0; i <= 20; i++) {
        w.sample('/rosout', at(i * 20)); // startup chatter, 50 Hz
        w.sample('/robot1/parameter_events', at(i * 20));
      }
      w.ignore(7); // e.g. a Zenoh subscription id
      for (var i = 0; i <= 10; i++) {
        w.sample(7, at(i * 100));
      }
      expect(w.silent(at(10000)), isFalse);
      expect(['/rosout', 'rt/rosout', '0/rosout/rcl_interfaces::msg::dds_::Log_', '/robot1/parameter_events']
          .every(LinkWatch.isEventTopic), isTrue);
      expect(['/odom', '/rosout_logger_level', '/scan'].any(LinkWatch.isEventTopic), isFalse);
    });

    test('one steady stream stopping while another continues is not a lost link', () {
      final w = LinkWatch();
      for (var i = 0; i <= 10; i++) {
        w.sample('odom', at(i * 100));
        w.sample('scan', at(i * 100));
      }
      for (var i = 11; i <= 40; i++) {
        w.sample('scan', at(i * 100)); // odom stopped at 1 s, scan goes on
      }
      expect(w.silent(at(4000)), isFalse);
      w.forget('scan');
      expect(w.silent(at(4000)), isTrue, reason: 'only the stopped odom is left');
    });

    test('nothing steady yet: never silent', () {
      final w = LinkWatch();
      w.sample('odom', at(0));
      w.sample('odom', at(100));
      expect(w.silent(at(60000)), isFalse);
    });
  });

  test('direct DDS: data stopping on every steady topic closes the connection', () async {
    final dds = FakeDds()..addRemote('rt/odom', 'nav_msgs::msg::dds_::Odometry_', reliable: false);
    final session = DirectRosSession(dds, 1, dds.codec);
    final ros = session.connect(ownsSession: true);
    final done = Completer<void>();
    ros.messages.listen((_) {}, onDone: done.complete);
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    final sample = dds.codec.encode('nav_msgs/msg/Odometry', const {});
    for (var i = 0; i < 15; i++) {
      dds.inject('rt/odom', sample);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(session.closed, isFalse);
    await done.future.timeout(const Duration(seconds: 3)); // the robot went quiet
    expect(session.lostReason, startsWith('Lost contact with the robot: no data for'));
    expect(ros.lastError, session.lostReason);
  });

  test('direct DDS: the robot vanishing from discovery closes the connection', () async {
    final dds = FakeDds()..addRemote('rt/odom', 'nav_msgs::msg::dds_::Odometry_');
    final session = DirectRosSession(dds, 1, dds.codec);
    final ros = session.connect(ownsSession: true);
    session.refreshGraph();
    expect(session.closed, isFalse);
    dds.robotGone = true;
    session.refreshGraph();
    expect(session.closed, isTrue);
    expect(ros.lastError, contains('no longer on the network'));
  });

  test('Zenoh: data stopping on every steady topic closes the connection', () async {
    final fake = FakeZenoh(tokens);
    final session = await ZenohRosSession.open(router: 'robot', backend: fake, interfaces: bundled());
    final ros = session.connect(ownsSession: true);
    final done = Completer<void>();
    ros.messages.listen((_) {}, onDone: done.complete);
    ros.send({'op': 'subscribe', 'topic': '/odom'});
    final sample = session.codec.encode('nav_msgs/msg/Odometry', const {});
    for (var i = 0; i < 15; i++) {
      fake.publish('0/odom/nav_msgs::msg::dds_::Odometry_/$odomHash', sample);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(session.closed, isFalse);
    await done.future.timeout(const Duration(seconds: 3));
    expect(session.lostReason, startsWith('Lost contact with the robot'));
  });
}
