/// The app's third way to reach a robot, next to rosbridge and direct DDS: a Zenoh client of the
/// robot's Zenoh router (ROS 2 with RMW_IMPLEMENTATION=rmw_zenoh_cpp). It needs no multicast and no
/// rosbridge: one TCP connection to `<robot>:7447`, which also works across subnets, through a VPN, or
/// over USB (`adb reverse tcp:7447 tcp:7447`).
///
/// Like the direct DDS connection, it speaks the rosbridge v2 ops the screens already use (subscribe,
/// publish, call_service, send_action_goal, …) and answers rosapi from the graph, so every screen works
/// unchanged. Messages are CDR, decoded with the same codec and bundled definitions as direct DDS.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import '../dds/cdr.dart';
import '../dds/direct_connection.dart' show loadBundledInterfaces, rosapiTypedefs;
import '../dds/custom_interfaces.dart';
import '../dds/ros_interfaces.dart';
import '../link_watch.dart';
import '../ros_connection.dart';
import 'zenoh_native.dart';
import 'zenoh_protocol.dart';

/// Whether this build can open a Zenoh connection at all (false on the web; see zenoh.dart).
const zenohSupported = true;

/// What the native layer reports (see native/zenoh/mobileros_zenoh.c).
class ZenohEvent {
  ZenohEvent(this.kind, this.id, {this.key = '', Uint8List? payload, Uint8List? attachment})
      : payload = payload ?? _empty,
        attachment = attachment ?? _empty;
  static final _empty = Uint8List(0);

  static const sample = 1, reply = 2, replyError = 3, queryDone = 4, alive = 5, gone = 6;

  final int kind;
  final int id;
  final String key;
  final Uint8List payload;
  final Uint8List attachment;
}

/// A Zenoh session: the native one, or a fake in tests.
abstract class ZenohBackend {
  String get zid;
  /// Data samples on [keyexpr] ([history]: also what history-keeping publishers stored), or with
  /// [liveliness] token alive/gone events ([history]: also the tokens that exist now).
  int subscribe(String keyexpr, {bool liveliness = false, bool history = false});
  void unsubscribe(int id);
  void put(String key, Uint8List payload, Uint8List attachment);
  /// A query (service call, or liveliness lookup); replies come as events with the returned id.
  int query(String key, {Uint8List? payload, Uint8List? attachment, Duration? timeout, bool liveliness = false});
  /// Announces a liveliness token (this app's node and endpoints in the ROS graph).
  int declareToken(String key);
  void undeclareToken(int id);
  ZenohEvent? poll();
  void close();
}

class _Query {
  final replies = <ZenohEvent>[];
  final done = Completer<List<ZenohEvent>>();
}

/// One Zenoh session shared by every screen of a connection (each screen gets a [connect] view).
class ZenohRosSession {
  ZenohRosSession(this.backend, this.codec, {this.domain = 0, this.timeout = const Duration(seconds: 8),
      math.Random? random})
      : random = random ?? math.Random.secure() {
    _graphSub = backend.subscribe('@ros2_lv/$domain/**', liveliness: true, history: true);
    _nodeToken = backend.declareToken('@ros2_lv/$domain/${backend.zid}/0/0/NN/%/%/$nodeName');
    _poll = Timer.periodic(const Duration(milliseconds: 20), (_) => tick());
  }

  /// How this app appears in `ros2 node list`.
  static const nodeName = 'mobile_ros';
  late final int _nodeToken;
  int _nextEntity = 1;

  /// Announces a subscription to [topic] as rmw_zenoh does. Publishers count subscribers from these
  /// tokens, and some (Nav2's /plan, for one) publish nothing while the count is zero.
  int declareSubscription(String topic, String ddsType, String typeHash) {
    final name = topic.replaceAll('/', '%');
    return backend.declareToken('@ros2_lv/$domain/${backend.zid}/0/${_nextEntity++}/MS/%/%/$nodeName/'
        '$name/$ddsType/$typeHash/::,10:,:,:,,');
  }

  void undeclare(int token) {
    try {
      backend.undeclareToken(token);
    } catch (_) {}
  }

  /// Connects to the Zenoh router at [router] (`host`, `host:port` or a full locator such as
  /// `tcp/10.0.0.5:7447`) and waits until the robot's graph shows up.
  static Future<ZenohRosSession> open({required String router, int domain = 0, ZenohBackend? backend,
      RosInterfaces? interfaces, Duration discoveryTimeout = const Duration(seconds: 6)}) async {
    backend ??= openNativeZenoh(zenohLocator(router));
    if (interfaces == null) {
      interfaces = await loadBundledInterfaces();
      (await loadCustomInterfaces()).forEach(interfaces.add);
    }
    final session = ZenohRosSession(backend, CdrCodec(interfaces), domain: domain);
    final until = DateTime.now().add(discoveryTimeout);
    while (session.graph.isEmpty && DateTime.now().isBefore(until)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (session.graph.isEmpty) {
      session.close();
      throw StateError('Connected to the Zenoh router, but no ROS 2 node answered on domain $domain. '
          'Check that the robot runs with RMW_IMPLEMENTATION=rmw_zenoh_cpp and the same ROS_DOMAIN_ID.');
    }
    return session;
  }

  final ZenohBackend backend;
  final CdrCodec codec;
  final int domain;
  final Duration timeout;
  final math.Random random;
  final graph = ZenohGraph();
  RosInterfaces get interfaces => codec.interfaces;

  late final int _graphSub;
  late final Timer _poll;
  final _routes = <int, void Function(ZenohEvent)>{};
  final _queries = <int, _Query>{};
  final _views = <ZenohRosConnection>{};
  bool closed = false;
  /// Watches the subscribed data so a silently lost link closes the connection like a dropped socket.
  final linkWatch = LinkWatch();
  DateTime _lastLinkCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Why the connection was closed when the robot was lost (null otherwise).
  String? lostReason;

  /// A view with its own subscriptions; closing the view leaves the session open unless [ownsSession].
  ZenohRosConnection connect({bool ownsSession = false}) {
    final view = ZenohRosConnection._(this, ownsSession);
    _views.add(view);
    return view;
  }

  int subscribe(String selector, void Function(ZenohEvent) onSample, {bool history = false}) {
    final id = backend.subscribe(selector, history: history);
    _routes[id] = onSample;
    if (LinkWatch.isEventTopic(selector)) linkWatch.ignore(id);
    return id;
  }

  void unsubscribe(int id) {
    _routes.remove(id);
    linkWatch.forget(id);
    try {
      backend.unsubscribe(id);
    } catch (_) {}
  }

  /// Sends a query and collects its replies until the router says there are no more.
  Future<List<ZenohEvent>> query(String key, {Uint8List? payload, Uint8List? attachment, Duration? timeout}) {
    final id = backend.query(key, payload: payload, attachment: attachment, timeout: timeout ?? this.timeout);
    final q = _queries[id] = _Query();
    return q.done.future;
  }

  void tick() {
    if (closed) return;
    for (var i = 0; i < 2000; i++) {
      final e = backend.poll();
      if (e == null) break;
      _dispatch(e);
    }
    for (final v in _views.toList()) {
      v._flushThrottled();
    }
    final now = DateTime.now();
    if (now.difference(_lastLinkCheck) >= const Duration(milliseconds: 250)) {
      _lastLinkCheck = now;
      if (linkWatch.silent(now)) _lose(lostContactMessage(linkWatch.quietFor(now)));
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

  void _dispatch(ZenohEvent e) {
    switch (e.kind) {
      case ZenohEvent.alive || ZenohEvent.gone when e.id == _graphSub:
        if (graph.apply(e.key, alive: e.kind == ZenohEvent.alive) && e.kind == ZenohEvent.alive) {
          for (final v in _views) {
            v._announcePending();
          }
        }
      case ZenohEvent.sample:
        final route = _routes[e.id];
        if (route != null) {
          linkWatch.sample(e.id, DateTime.now());
          route(e);
        }
      case ZenohEvent.reply || ZenohEvent.replyError:
        _queries[e.id]?.replies.add(e);
      case ZenohEvent.queryDone:
        final q = _queries.remove(e.id);
        if (q != null && !q.done.isCompleted) q.done.complete(q.replies);
    }
  }

  void close() {
    if (closed) return;
    closed = true;
    _poll.cancel();
    for (final v in _views.toList()) {
      v.close();
    }
    for (final q in _queries.values) {
      if (!q.done.isCompleted) q.done.completeError(StateError('Zenoh session closed'));
    }
    _queries.clear();
    undeclare(_nodeToken);
    try {
      backend.close();
    } catch (_) {}
  }
}

/// `robot`, `robot:7448` or `tcp/robot:7447` → a Zenoh locator (default port 7447).
String zenohLocator(String router) {
  final r = router.trim();
  if (r.contains('/')) return r;
  final hasPort = RegExp(r':\d+$').hasMatch(r) && !r.startsWith('[');
  return 'tcp/${hasPort ? r : '$r:7447'}';
}

/// Opens the native session (libmobileros_zenoh); tests pass a fake backend to [ZenohRosSession.open].
ZenohBackend Function(String locator) openNativeZenoh = NativeZenohBackend.open;

class _ZSub {
  _ZSub(this.topic);
  final String topic;
  final throttles = <String?, int>{}; // subscription id → throttle_rate (ms)
  int? backendId;
  bool history = false; // subscribed with history: a latched publisher's last message is fetched
  int? token; // our subscription's liveliness token, once the topic's type is known
  DateTime? lastEmit;
  ZenohEvent? held;
  bool warned = false;
  int get throttle => throttles.values.fold(1 << 30, math.min);
}

class _ZPub {
  _ZPub(this.rosType, this.gid);
  final String rosType;
  final Uint8List gid;
  int sequence = 0;
}

class _ZGoal {
  _ZGoal(this.id, this.action, this.uuid);
  final String? id;
  final String action;
  final Uint8List uuid;
  bool done = false;
}

/// One screen's view of a [ZenohRosSession], speaking rosbridge v2 ops.
class ZenohRosConnection implements RosConnection {
  ZenohRosConnection._(this.session, this.ownsSession) : _clientGid = randomId(session.random);

  final ZenohRosSession session;
  final bool ownsSession;
  final Uint8List _clientGid;
  int _requests = 0;
  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _subs = <String, _ZSub>{};
  final _pubs = <String, _ZPub>{};
  final _goals = <String, _ZGoal>{};
  final _feedbackSubs = <String, int>{}; // action → backend subscription
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

  CdrCodec get _codec => session.codec;
  int get _domain => session.domain;

  void _emit(Map<String, dynamic> m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  void _error(String text) => _emit({'op': 'status', 'level': 'error', 'msg': text});

  static String _ros(String t) => t.startsWith('/') ? t : '/$t';

  // ------------------------------------------------------------------------------ rosbridge ops

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
          _pubs[_ros('${message['topic']}')] ??=
              _ZPub(canonicalType('${message['type']}'), randomId(session.random));
        case 'unadvertise':
          _pubs.remove(_ros('${message['topic']}'));
        case 'publish':
          _publish(message);
        case 'call_service':
          _callServiceOp(message);
        case 'send_action_goal':
          _sendGoal(message);
        case 'cancel_action_goal':
          _cancelGoal(message);
        default:
          _error('Unsupported operation ${message['op']} on a Zenoh connection');
      }
    } catch (error) {
      _error('$error');
    }
  }

  void _subscribe(Map m) {
    final topic = _ros('${m['topic']}');
    final sub = _subs.putIfAbsent(topic, () => _ZSub(topic));
    sub.throttles[m['id'] as String?] = (m['throttle_rate'] as num?)?.toInt() ?? 0;
    if (sub.backendId != null) return;
    sub.history = _latched(topic);
    sub.backendId = session.subscribe(zenohTopicSelector(_domain, topic), (e) => _onSample(sub, e),
        history: sub.history);
    _announce(sub);
  }

  /// Whether a latched publisher (transient local, e.g. /map, AMCL's pose) keeps its last message for
  /// late subscribers.
  bool _latched(String topic) => session.graph
      .endpointsOf(topic, kinds: const {ZenohEntityKind.publisher})
      .any((e) => e.transientLocal);

  /// A subscription made before the graph showed its latched publisher (right after connecting, or
  /// before the publisher started) would otherwise wait for the next message, which for a latched
  /// topic may never come: found with four robots on Zenoh, where a robot standing still never
  /// showed its AMCL pose. Subscribe again with history once the publisher is known.
  void _upgradeLatched(_ZSub sub) {
    final id = sub.backendId;
    if (id == null || sub.history || !_latched(sub.topic)) return;
    sub.history = true;
    sub.backendId = session.subscribe(zenohTopicSelector(_domain, sub.topic), (e) => _onSample(sub, e), history: true);
    session.unsubscribe(id);
  }

  /// Declares the subscription token once a publisher (or subscriber) shows the topic's type and hash.
  void _announce(_ZSub sub) {
    if (sub.token != null) return;
    final e = session.graph.topicEndpoint(sub.topic);
    if (e != null) sub.token = session.declareSubscription(sub.topic, e.ddsType, e.typeHash);
  }

  void _announcePending() {
    for (final sub in _subs.values) {
      _announce(sub);
      _upgradeLatched(sub);
    }
  }

  void _unsubscribe(Map m) {
    final topic = _ros('${m['topic']}');
    final sub = _subs[topic];
    if (sub == null) return;
    if (m['id'] == null) {
      sub.throttles.clear();
    } else {
      sub.throttles.remove(m['id']);
    }
    if (sub.throttles.isEmpty) {
      _subs.remove(topic);
      final id = sub.backendId;
      if (id != null) session.unsubscribe(id);
      final token = sub.token;
      if (token != null) session.undeclare(token);
    }
  }

  void _onSample(_ZSub sub, ZenohEvent e) {
    if (sub.throttle > 0) {
      sub.held = e; // only the newest is kept until the throttle period is over
    } else {
      _deliver(sub, e);
    }
  }

  void _flushThrottled() {
    final now = DateTime.now();
    for (final sub in _subs.values) {
      final held = sub.held;
      if (held == null) continue;
      if (sub.lastEmit != null && now.difference(sub.lastEmit!).inMilliseconds < sub.throttle) continue;
      sub.held = null;
      sub.lastEmit = now;
      _deliver(sub, held);
    }
  }

  void _deliver(_ZSub sub, ZenohEvent e) {
    final type = zenohKeyType(e.key);
    final rosType = type == null ? null : rosTypeFromDds(type.$1);
    if (rosType == null) return;
    try {
      _emit({'op': 'publish', 'topic': sub.topic, 'msg': _codec.decode(rosType, e.payload)});
    } catch (error) {
      if (!sub.warned) {
        sub.warned = true;
        _error('Cannot read ${sub.topic} ($rosType): $error'
            '${session.interfaces.has(rosType) ? '' : '. Add its definition under Message definitions.'}');
      }
    }
  }

  void _publish(Map m) {
    final topic = _ros('${m['topic']}');
    final pub = _pubs[topic] ??
        (() {
          final known = session.graph.topicEndpoint(topic)?.rosType;
          if (known == null) throw StateError('Advertise $topic before publishing on it');
          return _pubs[topic] = _ZPub(known, randomId(session.random));
        })();
    final dds = ddsTypeName(pub.rosType);
    // rmw_zenoh puts the type hash in the key, so it has to be learned from the robot's own endpoints.
    final endpoint = session.graph
        .endpointsOf(topic, kinds: const {ZenohEntityKind.subscription, ZenohEntityKind.publisher})
        .where((e) => e.ddsType == dds)
        .firstOrNull;
    if (endpoint == null) {
      throw StateError('Nothing on the robot uses $topic (${pub.rosType}) yet, so there is nobody to send to.');
    }
    final payload = _codec.encode(pub.rosType, (m['msg'] as Map?) ?? const {});
    session.backend.put(endpoint.dataKey, payload,
        zenohAttachment(pub.sequence++, DateTime.now().microsecondsSinceEpoch * 1000, pub.gid));
  }

  // ------------------------------------------------------------------------------ services

  void _callServiceOp(Map m) {
    final service = '${m['service']}';
    call(service, Map<String, dynamic>.from((m['args'] as Map?) ?? const {})).then(
      (values) => _emit({'op': 'service_response', 'service': service, 'id': m['id'], 'values': values,
        'result': true}),
      onError: (Object e) => _emit({'op': 'service_response', 'service': service, 'id': m['id'],
        'values': '$e', 'result': false}),
    );
  }

  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    await ready;
    if (service.startsWith('/rosapi/')) return _rosapi(service.substring(8), args);
    final name = _ros(service);
    final server = session.graph.serviceServer(name);
    final type = server?.rosType;
    if (server == null || type == null) throw StateError('Service $name is not available');
    return _callService(server, type, args);
  }

  Future<Map<String, dynamic>> _callService(ZenohEntity server, String type, Map args,
      {Duration? timeout}) async {
    final request = _codec.encode('${type}_Request', args);
    final replies = await session.query(server.dataKey, payload: request,
        attachment: zenohAttachment(++_requests, DateTime.now().microsecondsSinceEpoch * 1000, _clientGid),
        timeout: timeout);
    for (final r in replies) {
      if (r.kind == ZenohEvent.reply) return _codec.decode('${type}_Response', r.payload);
    }
    final error = replies.where((r) => r.kind == ZenohEvent.replyError).firstOrNull;
    throw StateError(error == null
        ? 'No reply from ${server.name}'
        : 'Service ${server.name} failed: ${String.fromCharCodes(error.payload)}');
  }

  // ------------------------------------------------------------------------------ actions

  void _sendGoal(Map m) {
    final action = _ros('${m['action']}');
    final sendGoal = session.graph.serviceServer('$action/_action/send_goal');
    final sendType = sendGoal?.rosType; // e.g. nav2_msgs/action/NavigateToPose_SendGoal
    final goal = _ZGoal(m['id'] as String?, action, randomId(session.random));
    void fail(Object error) => _emit({'op': 'action_result', 'id': goal.id, 'action': action,
      'values': '$error', 'status': 0, 'result': false});
    if (sendGoal == null || sendType == null || !sendType.endsWith('_SendGoal')) {
      fail(StateError('Action $action is not available'));
      return;
    }
    final base = sendType.substring(0, sendType.length - '_SendGoal'.length);
    _goals[goal.id ?? action] = goal;
    if (m['feedback'] != false) _watchFeedback(action, base);
    () async {
      try {
        final accepted = await _callService(sendGoal, sendType, {
          'goal_id': {'uuid': goal.uuid},
          'goal': m['args'] ?? const {},
        });
        if (accepted['accepted'] != true) throw StateError('Goal was rejected');
        final getResult = session.graph.serviceServer('$action/_action/get_result');
        if (getResult == null) throw StateError('Action $action has no result service');
        final result = await _callService(getResult, '${base}_GetResult', {
          'goal_id': {'uuid': goal.uuid},
        }, timeout: const Duration(hours: 1));
        _emit({'op': 'action_result', 'id': goal.id, 'action': action, 'values': result['result'],
          'status': result['status'], 'result': true});
      } catch (error) {
        fail(error);
      } finally {
        goal.done = true;
        _goals.remove(goal.id ?? action);
      }
    }();
  }

  void _watchFeedback(String action, String base) {
    if (_feedbackSubs.containsKey(action)) return;
    final type = '${base}_FeedbackMessage';
    _feedbackSubs[action] = session.subscribe(zenohTopicSelector(_domain, '$action/_action/feedback'), (e) {
      try {
        final m = _codec.decode(type, e.payload);
        final uuid = Uint8List.fromList(((m['goal_id'] as Map)['uuid'] as List).cast<int>());
        for (final g in _goals.values) {
          if (g.action == action && !g.done && _same(uuid, g.uuid)) {
            _emit({'op': 'action_feedback', 'id': g.id, 'action': action, 'values': m['feedback']});
          }
        }
      } catch (_) {}
    });
  }

  static bool _same(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _cancelGoal(Map m) {
    final action = _ros('${m['action']}');
    final goal = _goals[m['id'] ?? action] ?? _goals.values.where((g) => g.action == action).firstOrNull;
    final cancel = session.graph.serviceServer('$action/_action/cancel_goal');
    if (goal == null || cancel == null) return;
    _callService(cancel, 'action_msgs/srv/CancelGoal', {
      'goal_info': {'goal_id': {'uuid': goal.uuid}, 'stamp': {'sec': 0, 'nanosec': 0}},
    }).catchError((Object e) {
      _error('Could not cancel the goal: $e');
      return <String, dynamic>{};
    });
  }

  // ------------------------------------------------------------------------------ rosapi

  Map<String, dynamic> _rosapi(String name, Map args) {
    final g = session.graph;
    const topicKinds = {ZenohEntityKind.publisher, ZenohEntityKind.subscription};
    List<String> services() => {for (final e in g.ofKind(ZenohEntityKind.serviceServer)) e.name}.toList()..sort();
    switch (name) {
      case 'topics':
        final types = <String, String>{};
        for (final e in g.entities) {
          final t = e.rosType;
          if (topicKinds.contains(e.kind) && t != null) types.putIfAbsent(e.name, () => t);
        }
        final names = types.keys.toList()..sort();
        return {'topics': names, 'types': [for (final n in names) types[n]]};
      case 'topic_type':
        return {'type': g.topicEndpoint(_ros('${args['topic']}'))?.rosType ?? ''};
      case 'publishers' || 'subscribers':
        final kind = name == 'publishers' ? ZenohEntityKind.publisher : ZenohEntityKind.subscription;
        return {name: {for (final e in g.endpointsOf(_ros('${args['topic']}'), kinds: {kind})) e.node}.toList()};
      case 'nodes':
        return {'nodes': g.nodeNames};
      case 'node_details':
        final node = '${args['node']}';
        final mine = g.entities.where((e) => e.kind != ZenohEntityKind.node && e.node == node);
        List<String> of(ZenohEntityKind k) => {for (final e in mine) if (e.kind == k) e.name}.toList()..sort();
        return {
          'publishing': of(ZenohEntityKind.publisher),
          'subscribing': of(ZenohEntityKind.subscription),
          'services': of(ZenohEntityKind.serviceServer),
        };
      case 'services':
        return {'services': services()};
      case 'service_type':
        return {'type': g.serviceServer(_ros('${args['service']}'))?.rosType ?? ''};
      case 'action_servers':
        const suffix = '/_action/send_goal';
        return {
          'action_servers': [
            for (final s in services())
              if (s.endsWith(suffix)) s.substring(0, s.length - suffix.length),
          ],
        };
      case 'interfaces':
        return {'interfaces': session.interfaces.allInterfaces.toList()..sort()};
      case 'message_details':
        return {'typedefs': rosapiTypedefs(session.interfaces, '${args['type']}')};
      case 'service_request_details' || 'service_response_details':
        final t = '${args['type']}'.split('/');
        final srv = t.length == 2 ? '${t[0]}/srv/${t[1]}' : '${args['type']}';
        return {
          'typedefs': rosapiTypedefs(session.interfaces,
              '$srv${name == 'service_request_details' ? '_Request' : '_Response'}'),
        };
    }
    throw StateError('/rosapi/$name is not available on a Zenoh connection');
  }

  // ------------------------------------------------------------------------------ lifecycle

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    for (final sub in _subs.values) {
      final id = sub.backendId;
      if (id != null) session.unsubscribe(id);
      final token = sub.token;
      if (token != null) session.undeclare(token);
    }
    _subs.clear();
    for (final id in _feedbackSubs.values) {
      session.unsubscribe(id);
    }
    _feedbackSubs.clear();
    session._views.remove(this);
    if (!_messages.isClosed) _messages.close();
    if (ownsSession) session.close();
  }
}
