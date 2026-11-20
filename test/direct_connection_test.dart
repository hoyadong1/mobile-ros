import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/dds/cdr.dart';
import 'package:ros_tester/dds/dds_native.dart';
import 'package:ros_tester/dds/direct_connection.dart';
import 'package:ros_tester/dds/ros_interfaces.dart';

import 'dds_cdr_test.dart' show bundled;

const self = '0000000000000000000000000000c1c1';
const robot = '0000000000000000000000000000abcd';

/// In-memory DDS: the app's entities plus a scripted robot.
class FakeDds implements DdsBackend {
  final codec = CdrCodec(bundled());
  final remote = <DdsEndpoint>[];
  bool robotIsFastDds = false;

  /// The robot left the network (its lease ran out): discovery no longer lists it.
  bool robotGone = false;
  final entities =
      <
        int,
        ({String topic, String type, bool isWriter, bool reliable, bool tl})
      >{};
  final queues = <int, List<Uint8List>>{};
  final written = <String, List<Uint8List>>{};

  /// Called with (topic, sample) whenever the app writes; lets tests play a service server.
  void Function(String topic, Uint8List sample)? onWrite;
  int _next = 10;

  void addRemote(
    String topic,
    String type, {
    bool writer = true,
    bool reliable = true,
    bool transientLocal = false,
    String? guid,
  }) => remote.add(
    DdsEndpoint(
      isWriter: writer,
      guid: guid ?? (remote.length + 1).toRadixString(16).padLeft(32, '0'),
      participant: robot,
      topic: topic,
      type: type,
      reliable: reliable,
      transientLocal: transientLocal,
    ),
  );

  /// Delivers [sample] to every app reader on [topic].
  void inject(String topic, Uint8List sample) {
    entities.forEach((id, e) {
      if (!e.isWriter && e.topic == topic) queues[id]!.add(sample);
    });
  }

  @override
  int open(int domain, String config) => 1;
  @override
  void close(int participant) {}
  @override
  String guid(int entity) =>
      entity == 1 ? self : entity.toRadixString(16).padLeft(32, 'e');
  @override
  int reader(
    int participant,
    String topic,
    String type, {
    required bool reliable,
    required bool transientLocal,
    int depth = 10,
  }) {
    final id = _next++;
    entities[id] = (
      topic: topic,
      type: type,
      isWriter: false,
      reliable: reliable,
      tl: transientLocal,
    );
    queues[id] = [];
    return id;
  }

  @override
  int writer(
    int participant,
    String topic,
    String type, {
    bool reliable = true,
    bool transientLocal = false,
    int depth = 10,
  }) {
    final id = _next++;
    entities[id] = (
      topic: topic,
      type: type,
      isWriter: true,
      reliable: reliable,
      tl: transientLocal,
    );
    return id;
  }

  @override
  void delete(int entity) {
    entities.remove(entity);
    queues.remove(entity);
  }

  @override
  int matched(int entity) => 1;
  @override
  void write(int writer, Uint8List data) {
    final topic = entities[writer]!.topic;
    (written[topic] ??= []).add(data);
    onWrite?.call(topic, data);
  }

  @override
  DdsSample? take(int reader, {bool withWriter = false}) {
    final q = queues[reader];
    if (q == null || q.isEmpty) return null;
    return (data: q.removeAt(0), writer: '');
  }

  @override
  DdsGraph graph(int participant) => DdsGraph(
    {self: false, if (!robotGone) robot: robotIsFastDds},
    [
      if (!robotGone) ...remote,
      for (final e in entities.entries)
        DdsEndpoint(
          isWriter: e.value.isWriter,
          guid: guid(e.key),
          participant: self,
          topic: e.value.topic,
          type: e.value.type,
          reliable: e.value.reliable,
          transientLocal: e.value.tl,
        ),
    ],
  );
}

Future<Map<String, dynamic>> next(
  DirectRosConnection c,
  bool Function(Map<String, dynamic>) test,
) => c.messages.firstWhere(test).timeout(const Duration(seconds: 2));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeDds dds;
  late DirectRosSession session;
  late DirectRosConnection ros;

  setUp(() {
    dds = FakeDds()
      ..addRemote('rt/odom', 'nav_msgs::msg::dds_::Odometry_', reliable: false)
      ..addRemote(
        'rt/map',
        'nav_msgs::msg::dds_::OccupancyGrid_',
        transientLocal: true,
      )
      ..addRemote(
        'rt/cmd_vel',
        'geometry_msgs::msg::dds_::Twist_',
        writer: false,
        guid: 'c0'.padLeft(32, '0'),
      )
      ..addRemote(
        'rq/reset_odomRequest',
        'std_srvs::srv::dds_::Trigger_Request_',
        writer: false,
      )
      ..addRemote(
        'rr/reset_odomReply',
        'std_srvs::srv::dds_::Trigger_Response_',
      );
    session = DirectRosSession(
      dds,
      1,
      dds.codec,
      readerRetention: const Duration(milliseconds: 60),
    );
    ros = session.connect();
  });
  tearDown(() => session.close());

  test(
    'subscriptions match the publisher QoS and deliver decoded messages',
    () async {
      ros.send({'op': 'subscribe', 'topic': '/odom'});
      ros.send({'op': 'subscribe', 'topic': '/map'});
      final odomReader = dds.entities.values.firstWhere(
        (e) => e.topic == 'rt/odom',
      );
      expect((odomReader.reliable, odomReader.tl), (false, false));
      final mapReader = dds.entities.values.firstWhere(
        (e) => e.topic == 'rt/map',
      );
      expect((mapReader.reliable, mapReader.tl), (true, true));

      final got = next(
        ros,
        (m) => m['op'] == 'publish' && m['topic'] == '/odom',
      );
      dds.inject(
        'rt/odom',
        dds.codec.encode('nav_msgs/msg/Odometry', {
          'header': {'frame_id': 'odom'},
          'pose': {
            'pose': {
              'position': {'x': 1.25},
            },
          },
        }),
      );
      final msg = (await got)['msg'] as Map;
      expect(msg['header']['frame_id'], 'odom');
      expect(msg['pose']['pose']['position']['x'], 1.25);

      ros.send({'op': 'unsubscribe', 'topic': '/odom'});
      expect(
        dds.entities.values.where((e) => e.topic == 'rt/odom'),
        hasLength(1),
        reason: 'the native reader is retained briefly for a route switch',
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(dds.entities.values.where((e) => e.topic == 'rt/odom'), isEmpty);
    },
  );

  test('throttled subscriptions only pass the newest sample', () async {
    ros.send({'op': 'subscribe', 'topic': '/odom', 'throttle_rate': 1000});
    final got = <double>[];
    final sub = ros.messages.listen(
      (m) => got.add(
        (m['msg']['twist']['twist']['linear']['x'] as num).toDouble(),
      ),
    );
    for (final v in [0.1, 0.2, 0.3]) {
      dds.inject(
        'rt/odom',
        dds.codec.encode('nav_msgs/msg/Odometry', {
          'twist': {
            'twist': {
              'linear': {'x': v},
            },
          },
        }),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    expect(got, [0.3]);
  });

  test('advertise + publish writes ROS 2 CDR on rt/<topic>', () {
    ros.send({
      'op': 'advertise',
      'topic': '/cmd_vel',
      'type': 'geometry_msgs/msg/Twist',
    });
    ros.send({
      'op': 'publish',
      'topic': '/cmd_vel',
      'msg': {
        'linear': {'x': 0.2},
        'angular': {'z': -0.5},
      },
    });
    final sent = dds.codec.decode(
      'geometry_msgs/msg/Twist',
      dds.written['rt/cmd_vel']!.single,
    );
    expect(sent['linear']['x'], 0.2);
    expect(sent['angular']['z'], -0.5);
    expect(
      dds.entities.values.firstWhere((e) => e.topic == 'rt/cmd_vel').type,
      'geometry_msgs::msg::dds_::Twist_',
    );
  });

  test(
    'rosapi answers come from discovery and the bundled definitions',
    () async {
      final discovery = dds.codec.encode(
        'rmw_dds_common/msg/ParticipantEntitiesInfo',
        {
          'gid': {
            'data': Uint8List.fromList([
              for (var i = 0; i < 32; i += 2)
                int.parse(robot.substring(i, i + 2), radix: 16),
              ...List.filled(8, 0),
            ]),
          },
          'node_entities_info_seq': [
            {
              'node_namespace': '/',
              'node_name': 'turtlebot3_diff_drive',
              'reader_gid_seq': [
                {
                  'data': Uint8List.fromList([
                    ...List.filled(15, 0),
                    0xc0,
                    ...List.filled(8, 0),
                  ]),
                },
              ],
              'writer_gid_seq': [],
            },
          ],
        },
      );
      dds.inject('ros_discovery_info', discovery);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final topics = await ros.call('/rosapi/topics');
      expect(topics['topics'], ['/cmd_vel', '/map', '/odom']);
      expect(topics['types'], [
        'geometry_msgs/msg/Twist',
        'nav_msgs/msg/OccupancyGrid',
        'nav_msgs/msg/Odometry',
      ]);
      expect(
        (await ros.call('/rosapi/subscribers', {
          'topic': '/cmd_vel',
        }))['subscribers'],
        ['/turtlebot3_diff_drive'],
      );
      expect(
        (await ros.call('/rosapi/publishers', {
          'topic': '/cmd_vel',
        }))['publishers'],
        isEmpty,
      );
      expect((await ros.call('/rosapi/nodes'))['nodes'], [
        '/turtlebot3_diff_drive',
      ]);
      expect(
        (await ros.call('/rosapi/node_details', {
          'node': '/turtlebot3_diff_drive',
        }))['subscribing'],
        ['/cmd_vel'],
      );
      expect((await ros.call('/rosapi/services'))['services'], ['/reset_odom']);
      expect(
        (await ros.call('/rosapi/service_type', {
          'service': '/reset_odom',
        }))['type'],
        'std_srvs/srv/Trigger',
      );
      final details = await ros.call('/rosapi/message_details', {
        'type': 'nav_msgs/msg/Odometry',
      });
      expect((details['typedefs'] as List).first['type'], 'nav_msgs/Odometry');
      final request = await ros.call('/rosapi/service_request_details', {
        'type': 'std_srvs/srv/SetBool',
      });
      expect((request['typedefs'] as List).first['fieldnames'], ['data']);
    },
  );

  for (final fastDds in [false, true]) {
    test(
      'service calls reach a ${fastDds ? 'Fast DDS' : 'Cyclone DDS'} server and get its reply',
      () async {
        dds.robotIsFastDds = fastDds;
        session.refreshGraph();
        dds.onWrite = (topic, sample) {
          if (topic != 'rq/reset_odomRequest') return;
          final reply = dds.codec.encode('std_srvs/srv/Trigger_Response', {
            'success': true,
            'message': 'reset',
          });
          // A stale reply for some other client arrives first and must be ignored by Cyclone-style calls.
          if (!fastDds) {
            dds.inject(
              'rr/reset_odomReply',
              Uint8List.fromList([
                ...reply.take(4),
                ...List.filled(16, 9),
                ...reply.skip(4),
              ]),
            );
            dds.inject(
              'rr/reset_odomReply',
              Uint8List.fromList([
                ...reply.take(4),
                ...sample.sublist(4, 20),
                ...reply.skip(4),
              ]),
            );
          } else {
            expect(
              sample.length,
              dds.codec.encode('std_srvs/srv/Trigger_Request', const {}).length,
            );
            dds.inject('rr/reset_odomReply', reply);
          }
        };
        final values = await ros.call('/reset_odom');
        expect(values, {'success': true, 'message': 'reset'});
      },
    );
  }

  test('send_action_goal runs the Nav2 action protocol', () async {
    const base = 'nav2_msgs::action::dds_::NavigateToPose';
    dds
      ..addRemote(
        'rq/navigate_to_pose/_action/send_goalRequest',
        '${base}_SendGoal_Request_',
        writer: false,
      )
      ..addRemote(
        'rr/navigate_to_pose/_action/send_goalReply',
        '${base}_SendGoal_Response_',
      )
      ..addRemote(
        'rq/navigate_to_pose/_action/get_resultRequest',
        '${base}_GetResult_Request_',
        writer: false,
      )
      ..addRemote(
        'rr/navigate_to_pose/_action/get_resultReply',
        '${base}_GetResult_Response_',
      )
      ..addRemote(
        'rt/navigate_to_pose/_action/feedback',
        '${base}_FeedbackMessage_',
      );
    session.refreshGraph();
    Uint8List reply(Uint8List request, String type, Map msg) {
      final body = dds.codec.encode(type, msg);
      return Uint8List.fromList([
        ...body.take(4),
        ...request.sublist(4, 20),
        ...body.skip(4),
      ]);
    }

    Map<String, dynamic>? goal;
    dds.onWrite = (topic, sample) {
      if (topic == 'rq/navigate_to_pose/_action/send_goalRequest') {
        final plain = Uint8List.fromList([
          ...sample.take(4),
          ...sample.skip(20),
        ]);
        goal = dds.codec.decode(
          'nav2_msgs/action/NavigateToPose_SendGoal_Request',
          plain,
        );
        dds.inject(
          'rr/navigate_to_pose/_action/send_goalReply',
          reply(sample, 'nav2_msgs/action/NavigateToPose_SendGoal_Response', {
            'accepted': true,
          }),
        );
        dds.inject(
          'rt/navigate_to_pose/_action/feedback',
          dds.codec.encode('nav2_msgs/action/NavigateToPose_FeedbackMessage', {
            'goal_id': goal!['goal_id'],
            'feedback': {'distance_remaining': 1.5},
          }),
        );
      } else if (topic == 'rq/navigate_to_pose/_action/get_resultRequest') {
        Timer(
          const Duration(milliseconds: 100),
          () => dds.inject(
            'rr/navigate_to_pose/_action/get_resultReply',
            reply(
              sample,
              'nav2_msgs/action/NavigateToPose_GetResult_Response',
              {'status': 4},
            ),
          ),
        );
      }
    };
    final feedback = next(ros, (m) => m['op'] == 'action_feedback');
    final result = next(ros, (m) => m['op'] == 'action_result');
    ros.send({
      'op': 'send_action_goal',
      'id': 'nav1',
      'action': '/navigate_to_pose',
      'action_type': 'nav2_msgs/action/NavigateToPose',
      'feedback': true,
      'args': {
        'pose': {
          'header': {'frame_id': 'map'},
          'pose': {
            'position': {'x': 2.0},
          },
        },
      },
    });
    expect((await feedback)['values']['distance_remaining'], 1.5);
    final r = await result;
    expect((r['id'], r['result'], r['status']), ('nav1', true, 4));
    expect(goal!['goal']['pose']['pose']['position']['x'], 2.0);
  });

  test('a reader nobody subscribes to is not drained; a returning page gets only the newest sample',
      () async {
    Uint8List odom(double x) => dds.codec.encode('nav_msgs/msg/Odometry', {
      'twist': {'twist': {'linear': {'x': x}}},
    });
    final first = session.connect();
    first.send({'op': 'subscribe', 'topic': '/odom'});
    final reader = dds.entities.entries.singleWhere((e) => e.value.topic == 'rt/odom').key;
    first.close(); // the reader is kept for the retention window

    for (final v in [0.1, 0.2, 0.3]) {
      dds.inject('rt/odom', odom(v));
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(dds.queues[reader], hasLength(3), reason: 'no copies while nobody is looking');

    final second = session.connect();
    final got = <double>[];
    final sub = second.messages.listen((m) {
      if (m['op'] == 'publish') got.add((m['msg']['twist']['twist']['linear']['x'] as num).toDouble());
    });
    second.send({'op': 'subscribe', 'topic': '/odom'});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(got, [0.3], reason: 'stale samples are skipped');
    dds.inject('rt/odom', odom(0.4));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(got, [0.3, 0.4], reason: 'live again: every sample');
    await sub.cancel();
    second.close();
  });

  test('a new view reuses the reader after the previous page closes', () async {
    final first = session.connect();
    first.send({'op': 'subscribe', 'topic': '/odom'});
    final firstReader = dds.entities.entries
        .singleWhere((e) => e.value.topic == 'rt/odom')
        .key;
    final firstEvent = next(
      first,
      (m) => m['op'] == 'publish' && m['topic'] == '/odom',
    );
    dds.inject(
      'rt/odom',
      dds.codec.encode('nav_msgs/msg/Odometry', {
        'header': {'frame_id': 'odom'},
      }),
    );
    expect((await firstEvent)['topic'], '/odom');
    first.close();

    final second = session.connect();
    second.send({'op': 'subscribe', 'topic': '/odom'});
    expect(
      dds.entities.entries.where((e) => e.value.topic == 'rt/odom'),
      hasLength(1),
    );
    expect(
      dds.entities.containsKey(firstReader),
      isTrue,
      reason: 'reuses the same native reader',
    );
    final secondEvent = next(
      second,
      (m) => m['op'] == 'publish' && m['topic'] == '/odom',
    );
    dds.inject(
      'rt/odom',
      dds.codec.encode('nav_msgs/msg/Odometry', {
        'header': {'frame_id': 'odom'},
      }),
    );
    expect((await secondEvent)['topic'], '/odom');
  });

  test(
    'closing a view releases its entities after the retention window but keeps the session',
    () async {
      final other = session.connect();
      other.send({'op': 'subscribe', 'topic': '/odom'});
      expect(
        dds.entities.values.where((e) => e.topic == 'rt/odom'),
        hasLength(1),
      );
      other.close();
      expect(
        dds.entities.values.where((e) => e.topic == 'rt/odom'),
        hasLength(1),
      );
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(dds.entities.values.where((e) => e.topic == 'rt/odom'), isEmpty);
      expect(ros.isClosed, isFalse);
    },
  );

  test('cyclone config names the interface and the robot as a peer', () {
    final xml = cycloneConfig(interface: 'wlan0', peer: '172.30.1.17');
    expect(xml, contains('<NetworkInterface name="wlan0"/>'));
    expect(xml, contains('<Peer address="172.30.1.17"/>'));
    expect(
      ddsTypeName('std_srvs/srv/Trigger_Request'),
      'std_srvs::srv::dds_::Trigger_Request_',
    );
  });
}
