import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/collision_watch.dart';

void main() {
  test('the monitor\'s topic is the robot\'s own', () {
    const type = 'nav2_msgs/msg/CollisionMonitorState';
    final topics = {'/collision_monitor_state': type, '/robot2/collision_monitor_state': type, '/odom': 'nav_msgs/msg/Odometry'};
    expect(collisionTopicIn(topics), '/collision_monitor_state');
    expect(collisionTopicIn(topics, namespace: '/robot2'), '/robot2/collision_monitor_state');
    expect(collisionTopicIn(topics, namespace: '/robot3'), isNull);
    expect(collisionTopicIn({'/odom': 'nav_msgs/msg/Odometry'}), isNull);
    expect(collisionTopicIn({'/a/cms': type, '/b/cms': type}), isNull, reason: 'two robots, no way to tell');
  });

  test('a report holds until the next one: the monitor speaks only when its state changes', () {
    final w = CollisionWatch();
    expect(w.current(), isNull);
    expect(w.onMessage({'action_type': 3, 'polygon_name': 'FootprintApproach'}), isTrue);
    expect(w.current(), (CollisionAction.approach, 'FootprintApproach'));
    expect(w.onMessage({'action_type': 3, 'polygon_name': 'FootprintApproach'}), isFalse,
        reason: 'the same thing again is not a change');
    expect(w.onMessage({'action_type': 1, 'polygon_name': 'stop_zone'}), isTrue);
    expect(w.current(), (CollisionAction.stop, 'stop_zone'), reason: 'still blocked minutes later');
    expect(w.onMessage({'action_type': 0, 'polygon_name': ''}), isTrue);
    expect(w.current(), isNull);
    expect(w.onMessage({'action_type': 0, 'polygon_name': ''}), isFalse);
    expect(w.onMessage('not a message'), isFalse);
    w.onMessage({'action_type': 2, 'polygon_name': 'slow'});
    w.clear();
    expect(w.current(), isNull);
  });
}
