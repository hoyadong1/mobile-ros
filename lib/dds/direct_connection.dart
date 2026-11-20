/// A [RosConnection] that talks ROS 2 over DDS directly, without rosbridge on the robot.
///
/// It speaks the same rosbridge v2 "ops" the pages already send (subscribe, advertise, publish,
/// call_service, send_action_goal, …) and answers the rosapi services they use from DDS discovery data
/// and bundled message definitions, so every page works unchanged on either connection.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../link_watch.dart';
import '../ros_connection.dart';
import 'cdr.dart';
import 'custom_interfaces.dart';
import 'dds_native.dart';
import 'ros_interfaces.dart';
export 'ros_interfaces.dart' show rosapiTypedefs;

/// What the session needs from DDS; [DdsNative] in the app, an in-memory fake in tests.
abstract class DdsBackend {
  int open(int domain, String config);
  void close(int participant);
  String guid(int entity);
  int reader(
    int participant,
    String topic,
    String type, {
    required bool reliable,
    required bool transientLocal,
    int depth,
  });
  int writer(
    int participant,
    String topic,
    String type, {
    bool reliable,
    bool transientLocal,
    int depth,
  });
  void delete(int entity);
  int matched(int entity);
  void write(int writer, Uint8List data);
  DdsSample? take(int reader, {bool withWriter});
  DdsGraph graph(int participant);
}

class NativeDdsBackend implements DdsBackend {
  NativeDdsBackend(this.n);
  final DdsNative n;
  @override
  int open(int domain, String config) => n.open(domain, config);
  @override
  void close(int participant) => n.close(participant);
  @override
  String guid(int entity) => n.guid(entity);
  @override
  int reader(
    int participant,
    String topic,
    String type, {
    required bool reliable,
    required bool transientLocal,
    int depth = 10,
  }) => n.reader(
    participant,
    topic,
    type,
    reliable: reliable,
    transientLocal: transientLocal,
    depth: depth,
  );
  @override
  int writer(
    int participant,
    String topic,
    String type, {
    bool reliable = true,
    bool transientLocal = false,
    int depth = 10,
  }) => n.writer(
    participant,
    topic,
    type,
    reliable: reliable,
    transientLocal: transientLocal,
    depth: depth,
  );
  @override
  void delete(int entity) => n.delete(entity);
  @override
  int matched(int entity) => n.matched(entity);
  @override
  void write(int writer, Uint8List data) => n.write(writer, data);
  @override
  DdsSample? take(int reader, {bool withWriter = false}) =>
      n.take(reader, withWriter: withWriter);
  @override
  DdsGraph graph(int participant) => n.graph(participant);
}

/// Cyclone DDS configuration: the interface facing the robot, and the robot as a unicast peer so
/// discovery also works where Wi-Fi drops multicast.
String cycloneConfig({String? interface, String? peer}) {
  final iface = interface == null
      ? '<NetworkInterface autodetermine="true"/>'
      : '<NetworkInterface name="$interface"/>';
  final peers = peer == null ? '' : '<Peers><Peer address="$peer"/></Peers>';
  // ParticipantIndex none = random unicast ports. With "auto" a reconnect gets the ports of the
  // connection just closed, and a Fast DDS robot that still lists the old readers at that address stops
  // delivering to the new ones. (MaxAutoParticipantIndex still sets how many robot ports a peer is probed on.)
  return '<CycloneDDS><Domain Id="any"><General><Interfaces>$iface</Interfaces></General>'
      '<Discovery><ParticipantIndex>none</ParticipantIndex><MaxAutoParticipantIndex>99</MaxAutoParticipantIndex>'
      '$peers</Discovery></Domain></CycloneDDS>';
}

/// The local interface to use for [robot]: one on the same /24, else Wi-Fi, else anything.
Future<(String?, String?)> pickInterface(String robot) async {
  InternetAddress? target;
  if (robot.trim().isNotEmpty) {
    target = InternetAddress.tryParse(robot.trim());
    if (target == null) {
      try {
        target = (await InternetAddress.lookup(
          robot.trim(),
          type: InternetAddressType.IPv4,
        )).firstOrNull;
      } catch (_) {}
    }
  }
  final interfaces = await NetworkInterface.list(
    type: InternetAddressType.IPv4,
  );
  if (target != null) {
    for (final i in interfaces) {
      for (final a in i.addresses) {
        if (a.rawAddress.length == 4 &&
            target.rawAddress.length == 4 &&
            a.rawAddress[0] == target.rawAddress[0] &&
            a.rawAddress[1] == target.rawAddress[1] &&
            a.rawAddress[2] == target.rawAddress[2]) {
          return (i.name, target.address);
        }
      }
    }
  }
  final wifi = interfaces.where((i) => i.name.startsWith('wlan')).firstOrNull;
  return (wifi?.name, target?.address);
}

const _network = MethodChannel('mobile_ros/network');

class _NodeInfo {
  _NodeInfo(this.name, this.readers, this.writers);
  final String name;
  final Set<String> readers, writers;
}

/// One DDS participant shared by every page (each page gets its own [DirectRosConnection] view).
class DirectRosSession {
  DirectRosSession(
    this.backend,
    this.participant,
    this.codec, {
    this.domain = 0,
    this.timeout = const Duration(seconds: 8),
    this.readerRetention,
  }) {
    selfGuid = backend.guid(participant);
    _discovery = backend.reader(
      participant,
      'ros_discovery_info',
      'rmw_dds_common::msg::dds_::ParticipantEntitiesInfo_',
      reliable: true,
      transientLocal: true,
      depth: 100,
    );
    _announce = backend.writer(
      participant,
      'ros_discovery_info',
      'rmw_dds_common::msg::dds_::ParticipantEntitiesInfo_',
      reliable: true,
      transientLocal: true,
      depth: 1,
    );
    _poll = Timer.periodic(const Duration(milliseconds: 20), (_) => _tick());
    _graphTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => refreshGraph(),
    );
    refreshGraph();
    _announceSelf();
  }

  /// Joins [domain] and waits until ROS 2 nodes show up. [robot] (IP or host name, may be empty) picks
  /// the network interface and is added as a discovery peer.
  static Future<DirectRosSession> open({
    required String robot,
    required int domain,
    DdsBackend? backend,
    RosInterfaces? interfaces,
    Duration discoveryTimeout = const Duration(seconds: 6),
  }) async {
    backend ??= switch (DdsNative.load()) {
      final n? => NativeDdsBackend(n),
      null => throw UnsupportedError(
        'Direct ROS 2 connection is not available on this device '
        '(${DdsNative.loadError}).',
      ),
    };
    if (interfaces == null) {
      interfaces = await loadBundledInterfaces();
      (await loadCustomInterfaces()).forEach(interfaces.add);
    }
    try {
      await _network.invokeMethod('acquireMulticast');
    } catch (_) {}
    final (iface, peer) = await pickInterface(robot);
    final participant = backend.open(
      domain,
      cycloneConfig(interface: iface, peer: peer),
    );
    final session = DirectRosSession(
      backend,
      participant,
      CdrCodec(interfaces),
      domain: domain,
    );
    try {
      await session._waitForRobot(discoveryTimeout);
    } catch (_) {
      session.close();
      rethrow;
    }
    return session;
  }

  final DdsBackend backend;
  final int participant;
  final CdrCodec codec;
  final int domain;
  final Duration timeout;
  /// How long an unused reader is kept before it is deleted; null (default) keeps it for the session.
  /// Deleting a reader and later creating another one on the same topic (or having two readers on one
  /// topic) stops samples from arriving altogether with Fast DDS publishers (seen on Humble), so the
  /// app keeps exactly one reader per topic for the whole connection.
  final Duration? readerRetention;

  /// Readers shared by every view and never deleted while connected (action feedback, service replies).
  final _rawReaders = <String, int>{};
  final serviceClients = <String, Future<_ServiceClient>>{};

  int sharedReader(String topic, String type, {required bool reliable, required bool transientLocal, int depth = 10}) =>
      _rawReaders[topic] ??= backend.reader(participant, topic, type,
          reliable: reliable, transientLocal: transientLocal, depth: depth);
  late final String selfGuid;
  late final int _discovery, _announce;
  late final Timer _poll, _graphTimer;
  DdsGraph graph = DdsGraph.empty;
  final _views = <DirectRosConnection>{};
  final _readers = <String, _PooledReader>{};
  final _nodes =
      <String, List<_NodeInfo>>{}; // participant GUID → its ROS nodes
  final _rng = math.Random.secure();
  bool closed = false;
  /// Watches the subscribed data so a silently lost link closes the connection like a dropped socket.
  final linkWatch = LinkWatch();
  DateTime _lastLinkCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Why the connection was closed when the robot was lost (null otherwise).
  String? lostReason;
  bool _sawRobot = false;
  bool _announcePending = false;

  RosInterfaces get interfaces => codec.interfaces;

  /// Interfaces the robot uses (topics, services, actions) that have no definition in the app yet.
  List<String> get unknownInterfaces => {
        for (final e in graph.endpoints)
          if (!isSelf(e))
            if (rosTypeFromDds(e.type) case final t? when !interfaces.has(t)) baseInterface(t),
      }.toList()
        ..sort();

  /// A new connection view; closing it releases only what it created (and the whole session if
  /// [ownsSession], for the app's main connection).
  DirectRosConnection connect({bool ownsSession = false}) {
    if (closed) throw StateError('Robot connection closed.');
    final view = DirectRosConnection._(this, ownsSession);
    _views.add(view);
    return view;
  }

  /// Waits until discovery has caught up: every remote participant has said which nodes it hosts
  /// (ros_discovery_info) and every reader/writer those nodes list is known. Discovery data arrives in
  /// bursts, so "the count stopped changing" alone returns too early. Fast DDS hands late joiners the
  /// latched ros_discovery_info only on its ~3 s heartbeat, and participants that are not ROS nodes
  /// never announce anything, so after 3 s a quiet period of 1.5 s is enough.
  Future<void> _waitForRobot(Duration limit) async {
    final watch = Stopwatch()..start();
    var last = -1;
    var stableSince = Duration.zero;
    while (watch.elapsed < limit) {
      refreshGraph();
      final count = graph.endpoints
          .where((e) => !isSelf(e) && e.topic.startsWith('rt/'))
          .length;
      if (count != last) {
        stableSince = watch.elapsed;
        last = count;
      }
      if (count > 0 &&
          (discoveryComplete ||
              (watch.elapsed > const Duration(seconds: 3) &&
                  watch.elapsed - stableSince >=
                      const Duration(milliseconds: 1500)))) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (last > 0) return;
    throw StateError('No ROS 2 nodes found on domain $domain.');
  }

  /// What [discoveryComplete] is still waiting for (for diagnostics).
  String get discoveryGaps {
    final known = {for (final e in graph.endpoints) e.guid};
    return [
      for (final p in graph.participants.keys.where((p) => p != selfGuid))
        if (!_nodes.containsKey(p))
          '${p.substring(0, 8)}…: no ros_discovery_info yet'
        else
          for (final n in _nodes[p]!)
            if (!known.containsAll(n.readers) || !known.containsAll(n.writers))
              '${n.name}: ${n.readers.difference(known).length + n.writers.difference(known).length} missing',
    ].join('; ');
  }

  /// Whether every endpoint announced by the remote ROS nodes has been discovered.
  bool get discoveryComplete {
    final remote = graph.participants.keys.where((p) => p != selfGuid).toList();
    if (remote.isEmpty || remote.any((p) => !_nodes.containsKey(p))) {
      return false;
    }
    final known = {for (final e in graph.endpoints) e.guid};
    for (final p in remote) {
      for (final n in _nodes[p]!) {
        if (!known.containsAll(n.readers) || !known.containsAll(n.writers)) {
          return false;
        }
      }
    }
    return true;
  }

  void refreshGraph() {
    if (closed) return;
    try {
      graph = backend.graph(participant);
    } catch (_) {
      return;
    }
    _nodes.removeWhere((p, _) => !graph.participants.containsKey(p));
    // Every remote participant gone: DDS dropped the robot after its lease ran out.
    final robotThere = graph.participants.keys.any((p) => p != selfGuid);
    if (robotThere) {
      _sawRobot = true;
    } else if (_sawRobot) {
      _lose('Lost contact with the robot: it is no longer on the network.');
      return;
    }
    for (final v in _views.toList()) {
      v._onGraph();
    }
  }

  /// Closes every view with [reason], as a dropped rosbridge socket would.
  void _lose(String reason) {
    if (closed) return;
    lostReason = reason;
    for (final v in _views.toList()) {
      v.lastError = reason;
    }
    close();
  }

  void _checkLink(DateTime now) {
    if (now.difference(_lastLinkCheck) < const Duration(milliseconds: 250)) return;
    _lastLinkCheck = now;
    if (linkWatch.silent(now)) _lose(lostContactMessage(linkWatch.quietFor(now)));
  }

  void _tick() {
    if (closed) return;
    _takeDiscovery();
    _pollReaders();
    for (final v in _views.toList()) {
      v._poll();
    }
    _checkLink(DateTime.now());
  }

  /// Poll each native reader once, then fan the sample out to every active page subscription.
  /// Keeping the entity briefly after its last page closes avoids a Cyclone/Fast DDS reader
  /// dispose/recreate race observed when Flutter routes switch between tools.
  void _pollReaders() {
    final now = DateTime.now();
    for (final pooled in _readers.values.toList()) {
      final active = [for (final s in pooled.subscribers) if (!s.owner.isClosed) s];
      if (active.isEmpty) {
        // Nobody is looking: leave samples in the reader (its KEEP_LAST history bounds them) instead of
        // copying every frame of a camera or map nobody displays.
        pooled.idle = true;
        linkWatch.forget(pooled.key); // not read now, so its silence says nothing about the link
        continue;
      }
      // Throttled-only readers are read when a subscriber is due, not every 20 ms tick.
      final due = active.any((s) => s.throttle <= 0 || s.lastEmit == null ||
          now.difference(s.lastEmit!).inMilliseconds >= s.throttle);
      if (!due) continue;
      // Back from idle: what queued meanwhile is stale, so only its newest sample is delivered (for a
      // latched topic such as /map that is exactly the one wanted).
      final resumed = pooled.idle;
      pooled.idle = false;
      DdsSample? newest;
      for (var i = 0; i < 200; i++) {
        final DdsSample? sample;
        try {
          sample = backend.take(pooled.reader);
        } catch (_) {
          break;
        }
        if (sample == null) break;
        linkWatch.sample(pooled.key, now);
        if (resumed) {
          newest = sample;
        } else {
          _fanOut(active, sample);
        }
      }
      if (newest != null) _fanOut(active, newest);
    }
  }

  void _fanOut(List<_Sub> subscribers, DdsSample sample) {
    for (final sub in subscribers) {
      if (sub.throttle <= 0) {
        sub.owner._deliver(sub, sample.data);
      } else {
        sub.held = sample.data;
      }
    }
  }


  void _attachReader(
    _Sub sub,
    String key,
    String topic,
    String type,
    (bool, bool) qos,
    int depth,
  ) {
    if (LinkWatch.isEventTopic(topic)) linkWatch.ignore(key);
    var pooled = _readers[key];
    if (pooled == null) {
      pooled = _PooledReader(
        key,
        backend.reader(
          participant,
          topic,
          type,
          reliable: qos.$1,
          transientLocal: qos.$2,
          depth: depth,
        ),
      );
      _readers[key] = pooled;
    }
    pooled.expiry?.cancel();
    pooled.expiry = null;
    pooled.subscribers.add(sub);
    sub.readerKey = key;
    sub.reader = pooled.reader;
    sub.qos = qos;
  }

  void _releaseReader(_Sub sub) {
    final key = sub.readerKey;
    sub.readerKey = null;
    sub.reader = null;
    if (key == null) return;
    final pooled = _readers[key];
    if (pooled == null) return;
    pooled.subscribers.remove(sub);
    if (pooled.subscribers.isNotEmpty || pooled.expiry != null) return;
    final retention = readerRetention;
    if (retention == null) return;
    pooled.expiry = Timer(retention, () {
      if (closed ||
          pooled.subscribers.isNotEmpty ||
          !identical(_readers[key], pooled)) {
        return;
      }
      _readers.remove(key);
      try {
        backend.delete(pooled.reader);
      } catch (_) {}
      entitiesChanged();
    });
    entitiesChanged();
  }

  void _takeDiscovery() {
    for (var i = 0; i < 50; i++) {
      final DdsSample? s;
      try {
        s = backend.take(_discovery);
      } catch (_) {
        return;
      }
      if (s == null) return;
      try {
        final info = codec.decode(
          'rmw_dds_common/msg/ParticipantEntitiesInfo',
          s.data,
        );
        String gid(Object? g) =>
            _hex(((g as Map)['data'] as List).cast<int>().take(16));
        final nodes = <_NodeInfo>[];
        for (final n in (info['node_entities_info_seq'] as List).cast<Map>()) {
          final ns = '${n['node_namespace']}';
          nodes.add(
            _NodeInfo(
              ns.endsWith('/')
                  ? '$ns${n['node_name']}'
                  : '$ns/${n['node_name']}',
              {for (final r in n['reader_gid_seq'] as List) gid(r)},
              {for (final w in n['writer_gid_seq'] as List) gid(w)},
            ),
          );
        }
        _nodes[gid(info['gid'])] = nodes;
      } catch (_) {}
    }
  }

  static String _hex(Iterable<int> bytes) =>
      [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

  bool isSelf(DdsEndpoint e) => e.participant == selfGuid;
  bool isFastDds(String participantGuid) =>
      graph.participants[participantGuid] ?? false;

  /// Remote ROS nodes, from what each participant announces on ros_discovery_info.
  List<String> get nodeNames => {
    for (final e in _nodes.entries)
      if (e.key != selfGuid)
        for (final n in e.value) n.name,
  }.toList()..sort();

  String nodeOf(DdsEndpoint e) {
    for (final n in _nodes[e.participant] ?? const <_NodeInfo>[]) {
      if (n.readers.contains(e.guid) || n.writers.contains(e.guid)) {
        return n.name;
      }
    }
    return '/_unknown_node_${e.participant.substring(0, 8)}';
  }

  List<DdsEndpoint> endpointsOfNode(String node) => [
    for (final e in graph.endpoints)
      if (!isSelf(e) && nodeOf(e) == node) e,
  ];

  Uint8List randomBytes(int n) =>
      Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

  /// Tells the ROS graph about this phone (node "/mobile_ros" with its publishers and subscriptions), so
  /// `ros2 node list` / `ros2 topic info` on the robot show it like any other node.
  void entitiesChanged() {
    if (_announcePending || closed) return;
    _announcePending = true;
    Timer(const Duration(milliseconds: 200), () {
      _announcePending = false;
      _announceSelf();
    });
  }

  void _announceSelf() {
    if (closed) return;
    Map<String, dynamic> gid(String hex) => {
      'data': Uint8List.fromList([
        for (var i = 0; i < 32; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
        ...List.filled(8, 0),
      ]),
    };
    final readers = <String>{}, writers = <String>{};
    for (final pooled in _readers.values) {
      try {
        readers.add(backend.guid(pooled.reader));
      } catch (_) {}
    }
    for (final v in _views) {
      readers.addAll(v._entityGuids(readers: true));
      writers.addAll(v._entityGuids(readers: false));
    }
    try {
      backend.write(
        _announce,
        codec.encode('rmw_dds_common/msg/ParticipantEntitiesInfo', {
          'gid': gid(selfGuid),
          'node_entities_info_seq': [
            {
              'node_namespace': '/',
              'node_name': 'mobile_ros',
              'reader_gid_seq': [for (final r in readers) gid(r)],
              'writer_gid_seq': [for (final w in writers) gid(w)],
            },
          ],
        }),
      );
    } catch (_) {}
  }

  void _removeView(DirectRosConnection v) {
    _views.remove(v);
    entitiesChanged();
  }

  void close() {
    if (closed) return;
    for (final v in _views.toList()) {
      v.close();
    }
    closed = true;
    for (final pooled in _readers.values) {
      pooled.expiry?.cancel();
    }
    _readers.clear();
    _poll.cancel();
    _graphTimer.cancel();
    try {
      backend.close(participant);
    } catch (_) {}
    _network.invokeMethod('releaseMulticast').catchError((_) => null);
  }
}

/// Whether this build can open a direct ROS 2 connection at all (false on the web; see direct.dart).
const directRosSupported = true;

Future<RosInterfaces> loadBundledInterfaces() async {
  final text = await rootBundle.loadString('assets/ros2_interfaces.json');
  return RosInterfaces(Map<String, String>.from(jsonDecode(text) as Map));
}

String _rosTopic(String t) => t.startsWith('/') ? t : '/$t';
String _ddsTopic(String rosTopic) => 'rt${_rosTopic(rosTopic)}';
const _heavyTypes = {
  'sensor_msgs/msg/Image',
  'sensor_msgs/msg/CompressedImage',
  'sensor_msgs/msg/PointCloud2',
};

class _Sub {
  _Sub(this.owner, this.topic);
  final DirectRosConnection owner;
  final String topic;
  final throttles = <String?, int>{}; // subscription id → throttle_rate (ms)
  String? rosType;
  int? reader;
  String? readerKey;
  (bool, bool)? qos;
  DateTime? lastEmit;
  Uint8List? held;
  bool warned = false;
  int get throttle => throttles.values.fold(1 << 30, math.min);
}

class _PooledReader {
  _PooledReader(this.key, this.reader);
  final String key;
  final int reader;
  final subscribers = <_Sub>{};
  Timer? expiry;
  /// Set while no page subscribes; samples then wait in the reader instead of being copied.
  bool idle = false;
}

class _Pub {
  _Pub(this.rosType, this.writer);
  final String rosType;
  final int writer;
}

class _ServiceClient {
  _ServiceClient(
    this.writer,
    this.reader,
    this.requestType,
    this.responseType,
    this.fastDds,
  );
  final int writer, reader;
  final String requestType, responseType;
  final bool fastDds;
  Future<void> busy = Future.value();
  int seq = 0;
}

class _Goal {
  _Goal(this.id, this.action, this.uuid);
  final String? id;
  final String action;
  final Uint8List uuid;
  bool done = false;
}

class DirectRosConnection implements RosConnection {
  DirectRosConnection._(this.session, this.ownsSession);
  final DirectRosSession session;
  final bool ownsSession;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _subs = <String, _Sub>{};
  final _pubs = <String, _Pub>{};
  final _services = <String, Future<_ServiceClient>>{};
  final _clients = <_ServiceClient>[];
  final _goals = <String, _Goal>{};
  final _feedbackReaders = <String, int>{}; // action → feedback reader
  bool _closed = false;

  @override
  String? lastError;
  @override
  Duration get timeout => session.timeout;
  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  bool get isClosed => _closed || session.closed;
  @override
  Future<void> get ready async {
    if (isClosed) throw StateError(lastError ?? 'Connection closed');
  }

  DdsBackend get _b => session.backend;
  CdrCodec get _codec => session.codec;

  void _emit(Map<String, dynamic> m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  void _error(String text) =>
      _emit({'op': 'status', 'level': 'error', 'msg': text});

  Iterable<String> _entityGuids({required bool readers}) sync* {
    final entities = readers
        ? [
            for (final s in _subs.values)
              if (s.reader != null) s.reader!,
            for (final c in _clients) c.reader,
            ..._feedbackReaders.values,
          ]
        : [
            for (final p in _pubs.values) p.writer,
            for (final c in _clients) c.writer,
          ];
    for (final e in entities) {
      try {
        yield _b.guid(e);
      } catch (_) {}
    }
  }

  // ---------------------------------------------------------------- rosbridge ops

  @override
  void send(Map<String, dynamic> message) {
    if (isClosed) throw StateError(lastError ?? 'Connection closed');
    try {
      switch (message['op']) {
        case 'subscribe':
          _subscribe(message);
        case 'unsubscribe':
          _unsubscribe(message);
        case 'advertise':
          _advertise(message);
        case 'unadvertise':
          _unadvertise(message);
        case 'publish':
          _publish(message);
        case 'call_service':
          _callServiceOp(message);
        case 'send_action_goal':
          _sendGoal(message);
        case 'cancel_action_goal':
          _cancelGoal(message);
        default:
          _error(
            'Unsupported operation ${message['op']} on a direct ROS 2 connection',
          );
      }
    } catch (error) {
      _error('$error');
    }
  }

  void _subscribe(Map m) {
    final topic = _rosTopic('${m['topic']}');
    final sub = _subs.putIfAbsent(topic, () => _Sub(this, topic));
    sub.throttles[m['id'] as String?] =
        (m['throttle_rate'] as num?)?.toInt() ?? 0;
    if (m['type'] is String && (m['type'] as String).isNotEmpty) {
      sub.rosType ??= canonicalType(m['type'] as String);
    }
    _ensureReader(sub);
  }

  void _unsubscribe(Map m) {
    final topic = _rosTopic('${m['topic']}');
    final sub = _subs[topic];
    if (sub == null) return;
    if (m['id'] == null) {
      sub.throttles.clear();
    } else {
      sub.throttles.remove(m['id']);
    }
    if (sub.throttles.isEmpty) {
      _subs.remove(topic);
      session._releaseReader(sub);
      session.entitiesChanged();
    }
  }

  /// QoS that matches every publisher of the topic: reliable/transient-local only if all of them are.
  (bool, bool) _qosFor(String ddsTopic) {
    final writers = session.graph.endpoints
        .where((e) => e.isWriter && e.topic == ddsTopic && !session.isSelf(e))
        .toList();
    if (writers.isEmpty) return (false, false);
    return (
      writers.every((w) => w.reliable),
      writers.every((w) => w.transientLocal),
    );
  }

  String? _graphType(String ddsTopic, {bool? writer}) {
    for (final e in session.graph.endpoints) {
      if (e.topic == ddsTopic && (writer == null || e.isWriter == writer)) {
        return e.type;
      }
    }
    return null;
  }

  void _ensureReader(_Sub sub) {
    final ddsTopic = _ddsTopic(sub.topic);
    final ddsType =
        _graphType(ddsTopic, writer: true) ??
        (sub.rosType == null ? null : ddsTypeName(sub.rosType!));
    if (ddsType == null) {
      return; // not on the network yet; retried when discovery changes
    }
    sub.rosType ??= rosTypeFromDds(ddsType);
    final qos = _qosFor(ddsTopic);
    final depth = _heavyTypes.contains(sub.rosType) ? 1 : 10;
    final key = ddsTopic; // one reader per topic, see DirectRosSession.readerRetention
    if (sub.reader != null && sub.readerKey == key) return;
    if (sub.reader != null) session._releaseReader(sub);
    session._attachReader(sub, key, ddsTopic, ddsType, qos, depth);
    session.entitiesChanged();
  }

  void _onGraph() {
    for (final sub in _subs.values) {
      try {
        _ensureReader(sub);
      } catch (_) {}
    }
  }

  void _poll() {
    if (isClosed) return;
    final now = DateTime.now();
    for (final sub in _subs.values.toList()) {
      final throttle = sub.throttle;
      if (throttle > 0 &&
          sub.held != null &&
          (sub.lastEmit == null ||
              now.difference(sub.lastEmit!).inMilliseconds >= throttle)) {
        final data = sub.held!;
        sub.held = null;
        sub.lastEmit = now;
        _deliver(sub, data);
      }
    }
    _pollFeedback();
  }

  void _deliver(_Sub sub, Uint8List data) {
    try {
      _emit({
        'op': 'publish',
        'topic': sub.topic,
        'msg': _codec.decode(sub.rosType!, data),
      });
    } catch (error) {
      if (!sub.warned) {
        sub.warned = true;
        _error('Cannot read ${sub.topic} (${sub.rosType}): $error'
            '${session.interfaces.has(sub.rosType!) ? '' : '. Add its definition under Message definitions.'}');
      }
    }
  }

  void _advertise(Map m) {
    final topic = _rosTopic('${m['topic']}');
    final type = canonicalType('${m['type']}');
    final existing = _pubs[topic];
    if (existing != null && existing.rosType == type) return;
    if (existing != null) _b.delete(existing.writer);
    if (!session.interfaces.has(type)) {
      throw StateError('No message definition for $type');
    }
    final writer = _b.writer(
      session.participant,
      _ddsTopic(topic),
      ddsTypeName(type),
      transientLocal: m['latch'] == true,
    );
    _pubs[topic] = _Pub(type, writer);
    session.entitiesChanged();
  }

  void _unadvertise(Map m) {
    final pub = _pubs.remove(_rosTopic('${m['topic']}'));
    if (pub != null) {
      _b.delete(pub.writer);
      session.entitiesChanged();
    }
  }

  void _publish(Map m) {
    final topic = _rosTopic('${m['topic']}');
    var pub = _pubs[topic];
    if (pub == null) {
      final ddsType = _graphType(_ddsTopic(topic));
      final type = ddsType == null ? null : rosTypeFromDds(ddsType);
      if (type == null) {
        throw StateError('Advertise $topic with its type before publishing');
      }
      _advertise({'topic': topic, 'type': type});
      pub = _pubs[topic]!;
    }
    _b.write(
      pub.writer,
      _codec.encode(pub.rosType, (m['msg'] as Map?) ?? const {}),
    );
  }

  void _callServiceOp(Map m) {
    final service = '${m['service']}';
    call(
      service,
      Map<String, dynamic>.from((m['args'] as Map?) ?? const {}),
    ).then(
      (values) => _emit({
        'op': 'service_response',
        'service': service,
        'id': m['id'],
        'values': values,
        'result': true,
      }),
      onError: (Object e) => _emit({
        'op': 'service_response',
        'service': service,
        'id': m['id'],
        'values': '$e',
        'result': false,
      }),
    );
  }

  // ---------------------------------------------------------------- services

  @override
  Future<Map<String, dynamic>> call(
    String service, [
    Map<String, dynamic> args = const {},
  ]) async {
    await ready;
    if (service.startsWith('/rosapi/')) {
      session.refreshGraph();
      return _rosapi(service.substring(8), args);
    }
    final name = _rosTopic(service);
    final type = _serviceType(name);
    if (type == null) throw StateError('Service $name is not available');
    return _callService(name, type, args);
  }

  /// `pkg/srv/Name` of a service, from its request topic on the network.
  String? _serviceType(String service) {
    final ddsType = _graphType('rq${service}Request');
    final ros = ddsType == null ? null : rosTypeFromDds(ddsType);
    return ros?.replaceFirst(RegExp(r'_Request$'), '');
  }

  Future<_ServiceClient> _client(String service, String type) {
    final pending = session.serviceClients[service] ??= _newClient(service, type);
    pending.catchError((Object _) {
      session.serviceClients.remove(service);
      return _ServiceClient(0, 0, '', '', false);
    });
    return pending;
  }

  Future<_ServiceClient> _newClient(String service, String type) async {
    final requestTopic = 'rq${service}Request',
        replyTopic = 'rr${service}Reply';
    final servers = session.graph.endpoints
        .where(
          (e) => !e.isWriter && e.topic == requestTopic && !session.isSelf(e),
        )
        .toList();
    if (servers.isEmpty) throw StateError('Service $service has no server');
    final requestType = '${type}_Request', responseType = '${type}_Response';
    final writer = _b.writer(
      session.participant,
      requestTopic,
      servers.first.type,
    );
    final reader = session.sharedReader(
      replyTopic,
      _graphType(replyTopic, writer: true) ?? ddsTypeName(responseType),
      reliable: true,
      transientLocal: false,
      depth: 50,
    );
    final client = _ServiceClient(
      writer,
      reader,
      requestType,
      responseType,
      session.isFastDds(servers.first.participant),
    );
    _clients.add(client);
    session.entitiesChanged();
    // Wait until both directions are matched, or the first request can be lost.
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 3) &&
        (_b.matched(writer) == 0 || _b.matched(reader) == 0)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return client;
  }

  /// Calls [service] of [type] (`pkg/srv/Name`, or an action's `pkg/action/Name_SendGoal` etc.).
  /// Cyclone-based servers echo a 16-byte request header we use to find our reply; Fast DDS servers
  /// identify requests out of band, so there the first reply after our request is taken.
  Future<Map<String, dynamic>> _callService(
    String service,
    String type,
    Map args, {
    Duration? limit = const Duration(seconds: 8),
  }) async {
    final client = await _client(service, type);
    final previous = client.busy;
    final done = Completer<void>();
    client.busy = done.future;
    await previous;
    try {
      while (_b.take(client.reader) !=
          null) {} // drop replies meant for earlier/other clients
      final body = _codec.encode(client.requestType, args);
      final Uint8List request;
      final Uint8List header;
      if (client.fastDds) {
        header = Uint8List(0);
        request = body;
      } else {
        header = Uint8List(16);
        header.setAll(0, session.randomBytes(8));
        ByteData.sublistView(header).setInt64(8, ++client.seq, Endian.little);
        request = Uint8List(body.length + 16)
          ..setRange(0, 4, body)
          ..setRange(4, 20, header)
          ..setRange(20, body.length + 16, body, 4);
      }
      _b.write(client.writer, request);
      final watch = Stopwatch()..start();
      while (limit == null || watch.elapsed < limit) {
        if (isClosed) throw StateError('Connection closed');
        final s = _b.take(client.reader);
        if (s == null) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          continue;
        }
        var data = s.data;
        if (!client.fastDds) {
          if (data.length < 20 || !_sameBytes(data, 4, header)) continue;
          data = Uint8List(data.length - 16)
            ..setRange(0, 4, data)
            ..setRange(4, data.length - 16, data, 20);
        }
        return _codec.decode(client.responseType, data);
      }
      throw TimeoutException('No reply from $service');
    } finally {
      done.complete();
    }
  }

  static bool _sameBytes(Uint8List data, int offset, Uint8List expected) {
    for (var i = 0; i < expected.length; i++) {
      if (data[offset + i] != expected[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- actions

  void _sendGoal(Map m) {
    final action = _rosTopic('${m['action']}');
    var type = '${m['action_type']}';
    final sendGoalType = _graphType('rq$action/_action/send_goalRequest');
    if (sendGoalType != null) {
      type = rosTypeFromDds(
        sendGoalType,
      )!.replaceFirst(RegExp(r'_SendGoal_Request$'), '');
    } else if (!type.contains('/action/')) {
      final p = type.split('/');
      type = '${p.first}/action/${p.last}';
    }
    final goal = _Goal(m['id'] as String?, action, session.randomBytes(16));
    final key = goal.id ?? action;
    _goals[key] = goal;
    if (m['feedback'] != false) _watchFeedback(action, type);
    () async {
      try {
        final accepted = await _callService(
          '$action/_action/send_goal',
          '${type}_SendGoal',
          {
            'goal_id': {'uuid': goal.uuid},
            'goal': m['args'] ?? const {},
          },
        );
        if (accepted['accepted'] != true) throw StateError('Goal was rejected');
        final result = await _callService(
          '$action/_action/get_result',
          '${type}_GetResult',
          {
            'goal_id': {'uuid': goal.uuid},
          },
          limit: null,
        );
        _emit({
          'op': 'action_result',
          'id': goal.id,
          'action': action,
          'values': result['result'],
          'status': result['status'],
          'result': true,
        });
      } catch (error) {
        _emit({
          'op': 'action_result',
          'id': goal.id,
          'action': action,
          'values': '$error',
          'status': 0,
          'result': false,
        });
      } finally {
        goal.done = true;
        _goals.remove(key);
      }
    }();
  }

  void _watchFeedback(String action, String type) {
    if (_feedbackReaders.containsKey(action)) return;
    final topic = 'rt$action/_action/feedback';
    _feedbackReaders[action] = session.sharedReader(
      topic,
      _graphType(topic, writer: true) ?? ddsTypeName('${type}_FeedbackMessage'),
      reliable: false,
      transientLocal: false,
    );
    _feedbackTypes[action] = '${type}_FeedbackMessage';
    session.entitiesChanged();
  }

  final _feedbackTypes = <String, String>{};

  void _pollFeedback() {
    for (final entry in _feedbackReaders.entries) {
      for (var i = 0; i < 50; i++) {
        final DdsSample? s;
        try {
          s = _b.take(entry.value);
        } catch (_) {
          break;
        }
        if (s == null) break;
        try {
          final m = _codec.decode(_feedbackTypes[entry.key]!, s.data);
          final uuid = ((m['goal_id'] as Map)['uuid'] as List).cast<int>();
          for (final g in _goals.values) {
            if (g.action == entry.key &&
                !g.done &&
                _sameBytes(Uint8List.fromList(uuid), 0, g.uuid)) {
              _emit({
                'op': 'action_feedback',
                'id': g.id,
                'action': g.action,
                'values': m['feedback'],
              });
            }
          }
        } catch (_) {}
      }
    }
  }

  void _cancelGoal(Map m) {
    final action = _rosTopic('${m['action']}');
    final goal =
        _goals[m['id'] ?? action] ??
        _goals.values.where((g) => g.action == action).firstOrNull;
    if (goal == null) return;
    _callService('$action/_action/cancel_goal', 'action_msgs/srv/CancelGoal', {
      'goal_info': {
        'goal_id': {'uuid': goal.uuid},
        'stamp': {'sec': 0, 'nanosec': 0},
      },
    }).catchError((Object e) {
      _error('Could not cancel the goal: $e');
      return <String, dynamic>{};
    });
  }

  // ---------------------------------------------------------------- rosapi

  Map<String, dynamic> _rosapi(String name, Map args) {
    final g = session.graph;
    final remote = g.endpoints.where((e) => !session.isSelf(e));
    switch (name) {
      case 'topics':
        final types = <String, String>{};
        for (final e in g.endpoints) {
          if (!e.topic.startsWith('rt/')) continue;
          final t = rosTypeFromDds(e.type);
          if (t != null) types.putIfAbsent(e.topic.substring(2), () => t);
        }
        final names = types.keys.toList()..sort();
        return {
          'topics': names,
          'types': [for (final n in names) types[n]],
        };
      case 'topic_type':
        final t = _graphType(_ddsTopic('${args['topic']}'));
        return {'type': t == null ? '' : rosTypeFromDds(t) ?? ''};
      case 'publishers' || 'subscribers':
        final topic = _ddsTopic('${args['topic']}');
        final writers = name == 'publishers';
        return {
          name: {
            for (final e in remote)
              if (e.topic == topic && e.isWriter == writers) session.nodeOf(e),
          }.toList(),
        };
      case 'nodes':
        return {'nodes': session.nodeNames};
      case 'node_details':
        final eps = session.endpointsOfNode('${args['node']}');
        List<String> topics(bool writer) => {
          for (final e in eps)
            if (e.isWriter == writer && e.topic.startsWith('rt/'))
              e.topic.substring(2),
        }.toList()..sort();
        return {
          'publishing': topics(true),
          'subscribing': topics(false),
          'services': _serviceNames(eps.where((e) => !e.isWriter)),
        };
      case 'services':
        return {'services': _serviceNames(remote.where((e) => !e.isWriter))};
      case 'service_type':
        return {'type': _serviceType(_rosTopic('${args['service']}')) ?? ''};
      case 'action_servers':
        return {
          'action_servers': [
            for (final s in _serviceNames(remote.where((e) => !e.isWriter)))
              if (s.endsWith('/_action/send_goal'))
                s.substring(0, s.length - '/_action/send_goal'.length),
          ],
        };
      case 'interfaces':
        return {
          'interfaces': session.interfaces.allInterfaces.toList()..sort(),
        };
      case 'message_details':
        return {
          'typedefs': rosapiTypedefs(session.interfaces, '${args['type']}'),
        };
      case 'service_request_details' || 'service_response_details':
        final part = name == 'service_request_details'
            ? '_Request'
            : '_Response';
        return {
          'typedefs': rosapiTypedefs(
            session.interfaces,
            '${_srvType('${args['type']}')}$part',
          ),
        };
    }
    throw StateError(
      '/rosapi/$name is not available on a direct ROS 2 connection',
    );
  }

  static String _srvType(String t) {
    final p = t.split('/');
    return p.length == 2 ? '${p[0]}/srv/${p[1]}' : t;
  }

  static List<String> _serviceNames(Iterable<DdsEndpoint> readers) => {
    for (final e in readers)
      if (e.topic.startsWith('rq/') && e.topic.endsWith('Request'))
        e.topic.substring(2, e.topic.length - 7),
  }.toList()..sort();

  // ---------------------------------------------------------------- lifecycle

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    lastError ??= 'Connection closed';
    for (final s in _subs.values) {
      session._releaseReader(s);
    }
    for (final p in _pubs.values) {
      _tryDelete(p.writer);
    }
    _subs.clear();
    _pubs.clear();
    _services.clear();
    _clients.clear();
    _feedbackReaders.clear();
    _messages.close();
    session._removeView(this);
    if (ownsSession) session.close();
  }

  void _tryDelete(int e) {
    try {
      _b.delete(e);
    } catch (_) {}
  }
}
