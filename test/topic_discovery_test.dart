import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/topic_discovery.dart';
import 'support/fake_ros_connection.dart';

void main() {
  const topics = {
    'topics': ['/odom', '/robot1/odom', '/robot1/odometry/filtered', '/robot1/goal_pose', '/goal_pose'],
    'types': ['nav_msgs/msg/Odometry', 'nav_msgs/msg/Odometry', 'nav_msgs/Odometry',
      'geometry_msgs/msg/PoseStamped', 'geometry_msgs/msg/PoseStamped'],
  };

  test('type matching accepts ROS 1 and ROS 2 spellings; names rank exact, then namespaced', () {
    expect(topicsOfType(topics, 'nav_msgs/Odometry'), ['/odom', '/robot1/odom', '/robot1/odometry/filtered']);
    expect(rankByName(['/a/odometry', '/robot1/odom', '/odom'], 'odom'), ['/odom', '/robot1/odom', '/a/odometry']);
  });

  test('a listed topic without a publisher loses to a published namespaced one', () async {
    final robot = FakeConnection()
      ..serviceResponses['/rosapi/publishers'] = {'publishers': []};
    addTearDown(robot.close);
    // Answer per topic: only /robot1/odom has a publisher.
    final fake = _PerTopic(robot, {'/robot1/odom': ['/gazebo']});
    expect(await pickTopic(fake, topics, 'nav_msgs/Odometry', 'odom'), '/robot1/odom');
  });

  test('topics the app writes to need a subscriber', () async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    final fake = _PerTopic(robot, {}, subscribers: {'/robot1/goal_pose': ['/bt_navigator']});
    expect(await pickTopic(fake, topics, 'geometry_msgs/PoseStamped', 'goal_pose', role: TopicRole.write),
        '/robot1/goal_pose');
  });

  test('without introspection answers the best name wins; a single candidate is used as is', () async {
    final robot = FakeConnection();
    addTearDown(robot.close);
    expect(await pickTopic(robot, topics, 'nav_msgs/Odometry', 'odom'), '/odom');
    expect(await pickTopic(robot, {'topics': ['/x/scan'], 'types': ['sensor_msgs/msg/LaserScan']},
        'sensor_msgs/LaserScan', 'scan'), '/x/scan');
    expect(await pickTopic(robot, null, 'sensor_msgs/LaserScan', 'scan'), isNull);
  });
}

/// Answers /rosapi/publishers and /rosapi/subscribers per topic.
class _PerTopic extends FakeConnection {
  _PerTopic(this.inner, this.publishers, {this.subscribers = const {}});
  final FakeConnection inner;
  final Map<String, List<String>> publishers, subscribers;

  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    final topic = args['topic'];
    if (service == '/rosapi/publishers') return {'publishers': publishers[topic] ?? []};
    if (service == '/rosapi/subscribers') return {'subscribers': subscribers[topic] ?? []};
    return inner.call(service, args);
  }
}
