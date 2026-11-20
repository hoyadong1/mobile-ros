/// The app's fourth way to reach a robot: the Foxglove WebSocket protocol (`foxglove.websocket.v1`), as
/// served by `foxglove_bridge` (ROS 2, port 8765 by default). More and more ROS 2 robots run it for
/// Foxglove; with this the app needs no rosbridge on them.
///
/// Like the direct DDS and Zenoh connections, it speaks the rosbridge v2 ops the screens already use
/// (subscribe, advertise, publish, call_service, send_action_goal) and answers rosapi from what the
/// bridge advertises, so every screen works unchanged. Messages are CDR, read and written with the
/// same codec and bundled definitions; definitions the robot advertises fill in its own types.
///
/// Plain WebSocket, so it also works in the browser build.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'dds/cdr.dart';
import 'dds/custom_interfaces.dart';
import 'dds/ros_interfaces.dart';
import 'ros_connection.dart';

class _Channel {
  _Channel(this.id, this.topic, this.encoding, this.type);
  final int id;
  final String topic, encoding, type;
}

class _Service {
  _Service(this.id, this.name, this.type);
  final int id;
  final String name, type;
}

class _Sub {
  _Sub(this.topic);
  final String topic;
  int? id; // the bridge subscription, once the topic is advertised
  int? channel; // the bridge channel it is on (a topic may be advertised again under a new id)
  final throttles = <String?, int>{};
  int get throttle => throttles.isEmpty ? 0 : throttles.values.reduce(math.min);
  DateTime? lastEmit;
  Map<String, dynamic>? held;
  bool warned = false;
}

class _Goal {
  _Goal(this.id, this.action, this.uuid);
  final String? id;
  final String action;
  final Uint8List uuid;
  bool done = false;
}

class FoxgloveRosConnection implements RosConnection {
  /// [incoming] are the socket's frames (text or bytes), [outgoing] sends one. Use [connect] in the app.
  FoxgloveRosConnection(Stream<dynamic> incoming, this._outgoing, this.codec,
      {this.timeout = const Duration(seconds: 8), this.onClose, math.Random? random})
      : _random = random ?? math.Random.secure() {
    _socket = incoming.listen(_onFrame, onError: (Object e) => _fail('$e'), onDone: () => _fail(null));
    _flush = Timer.periodic(const Duration(milliseconds: 50), (_) => _flushThrottled());
  }

  /// Opens `ws://host:port` (8765 is foxglove_bridge's default) and waits for the bridge's hello.
  static Future<FoxgloveRosConnection> connect(String host, String port,
      {Duration timeout = const Duration(seconds: 8)}) async {
    final connection = open(host, port, await loadInterfaces(), timeout: timeout);
    final uri = address(host, port);
    try {
      await connection.ready.timeout(timeout);
    } on TimeoutException {
      connection.close();
      throw StateError('No Foxglove bridge answered at $uri. Check that foxglove_bridge runs on the robot '
          '(ros2 launch foxglove_bridge foxglove_bridge_launch.xml) and the port.');
    }
    return connection;
  }

  /// The bundled ROS 2 definitions and the user's own (Message definitions screen).
  static Future<RosInterfaces> loadInterfaces() async {
    final interfaces = RosInterfaces(Map<String, String>.from(
        jsonDecode(await rootBundle.loadString('assets/ros2_interfaces.json')) as Map));
    (await loadCustomInterfaces()).forEach(interfaces.add);
    return interfaces;
  }

  /// foxglove_bridge 3 (Foxglove SDK) answers only to the first, older bridges only to the second; the
  /// messages are the same.
  static const subprotocols = ['foxglove.sdk.v1', 'foxglove.websocket.v1'];

  static Uri address(String host, String port) => Uri.parse(host.contains('://') ? host : 'ws://$host:$port');

  /// A connection that becomes [ready] when the bridge says hello (each screen opens its own, as with
  /// rosbridge).
  static FoxgloveRosConnection open(String host, String port, RosInterfaces interfaces,
      {Duration timeout = const Duration(seconds: 8)}) {
    final channel = WebSocketChannel.connect(address(host, port), protocols: subprotocols);
    return FoxgloveRosConnection(channel.stream, channel.sink.add, CdrCodec(interfaces),
        timeout: timeout, onClose: () => channel.sink.close());
  }

  final void Function(Object) _outgoing;
  final CdrCodec codec;
  @override
  final Duration timeout;
  /// Closes the socket (the app's [connect] passes it).
  final void Function()? onClose;
  final math.Random _random;
  late final StreamSubscription<dynamic> _socket;
  late final Timer _flush;

  final _messages = StreamController<Map<String, dynamic>>.broadcast();
  final _ready = Completer<void>();
  Timer? _helloTimer;
  /// Ops a screen sent before the bridge said what it can do: run once it has.
  final _early = <Map<String, dynamic>>[];

  void _becomeReady() {
    _helloTimer?.cancel();
    if (_ready.isCompleted || _closed) return;
    _ready.complete();
    final early = List.of(_early);
    _early.clear();
    early.forEach(send);
  }
  bool _closed = false;
  @override
  String? lastError;

  /// What the bridge says it can do ("clientPublish", "services", "connectionGraph", …).
  final capabilities = <String>{};
  final _channels = <int, _Channel>{}; // the bridge's, by id
  final _byTopic = <String, _Channel>{};
  final _services = <String, _Service>{};
  final _subs = <String, _Sub>{};
  final _subsById = <int, _Sub>{};
  int _nextSub = 1, _nextClientChannel = 1, _nextCall = 1;
  final _clientChannels = <String, (int, String)>{}; // topic -> (channel id, type)
  final _calls = <int, (Completer<Map<String, dynamic>>, String)>{};
  final _goals = <String, _Goal>{};
  final _publishers = <String, Set<String>>{}, _subscribers = <String, Set<String>>{};
  /// The first node graph comes a moment after the hello: questions about nodes wait for it.
  final _graphSeen = Completer<void>();

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;
  @override
  bool get isClosed => _closed;
  @override
  Future<void> get ready => _ready.future;

  void _emit(Map<String, dynamic> m) {
    if (!_messages.isClosed) _messages.add(m);
  }

  void _error(String text) => _emit({'op': 'status', 'level': 'error', 'msg': text});

  static String _ros(String t) => t.startsWith('/') ? t : '/$t';

  void _fail(String? error) {
    if (_closed) return;
    lastError = error ?? lastError ?? 'The Foxglove bridge closed the connection';
    if (!_ready.isCompleted) _ready.completeError(StateError(lastError!));
    close();
  }

  void _sendJson(Map<String, Object?> m) {
    if (!_closed) _outgoing(jsonEncode(m));
  }

  // ------------------------------------------------------------------------------ from the bridge

  void _onFrame(dynamic frame) {
    try {
      if (frame is String) {
        _onJson(jsonDecode(frame) as Map<String, dynamic>);
      } else if (frame is List<int>) {
        _onBinary(frame is Uint8List ? frame : Uint8List.fromList(frame));
      }
    } catch (e) {
      _error('Unreadable message from the Foxglove bridge: $e');
    }
  }

  void _onJson(Map<String, dynamic> m) {
    switch (m['op']) {
      case 'serverInfo':
        capabilities.addAll([for (final c in (m['capabilities'] as List? ?? const [])) '$c']);
        if (capabilities.contains('connectionGraph')) _sendJson({'op': 'subscribeConnectionGraph'});
        // The topics come in a moment after the hello: screens ask for them right away, so wait for the
        // first announcement (or a second, for a bridge with nothing to announce).
        _helloTimer = Timer(const Duration(seconds: 1), _becomeReady);
      case 'status':
        if (m['level'] == 2) _error('Foxglove bridge: ${m['message']}');
      case 'advertise':
        for (final c in (m['channels'] as List? ?? const [])) {
          final ch = _Channel((c['id'] as num).toInt(), _ros('${c['topic']}'), '${c['encoding']}',
              canonicalType('${c['schemaName']}'));
          _learn(ch.type, c['schema'], c['schemaEncoding']);
          _channels[ch.id] = ch;
          _byTopic[ch.topic] = ch;
          final sub = _subs[ch.topic];
          if (sub != null && sub.channel != ch.id) {
            final old = sub.id;
            if (old != null) {
              _subsById.remove(old);
              _sendJson({'op': 'unsubscribe', 'subscriptionIds': [old]});
            }
            _subscribeChannel(sub, ch);
          }
        }
        _becomeReady();
      case 'unadvertise':
        for (final id in (m['channelIds'] as List? ?? const [])) {
          final ch = _channels.remove((id as num).toInt());
          if (ch == null) continue;
          if (_byTopic[ch.topic]?.id == ch.id) _byTopic.remove(ch.topic);
          final sub = _subs[ch.topic];
          if (sub == null || sub.channel != ch.id) continue;
          _subsById.remove(sub.id);
          sub.id = null;
          sub.channel = null; // subscribed again if the topic comes back
          final other = _byTopic[ch.topic];
          if (other != null) _subscribeChannel(sub, other);
        }
      case 'advertiseServices':
        for (final s in (m['services'] as List? ?? const [])) {
          final type = _serviceType('${s['type']}');
          _services[_ros('${s['name']}')] = _Service((s['id'] as num).toInt(), _ros('${s['name']}'), type);
          // A service's definition is "request --- response" (older bridges: requestSchema/responseSchema).
          final request = s['request'], response = s['response'];
          final req = request is Map ? request['schema'] : s['requestSchema'];
          final res = response is Map ? response['schema'] : s['responseSchema'];
          if (req is String && res is String && !codec.interfaces.has('${type}_Request')) {
            final a = _learn(null, req, null), b = _learn(null, res, null);
            if (a != null && b != null) codec.interfaces.add(type, '$a\n---\n$b');
          }
        }
      case 'unadvertiseServices':
        final ids = {for (final id in (m['serviceIds'] as List? ?? const [])) (id as num).toInt()};
        _services.removeWhere((_, s) => ids.contains(s.id));
      case 'serviceCallFailure':
        final call = _calls.remove((m['callId'] as num?)?.toInt());
        call?.$1.completeError(StateError('Service ${call.$2} failed: ${m['message']}'));
      case 'connectionGraphUpdate':
        void merge(Map<String, Set<String>> into, Object? list, String ids) {
          for (final t in (list as List? ?? const [])) {
            into[_ros('${t['name']}')] = {for (final n in (t[ids] as List? ?? const [])) '$n'};
          }
        }
        merge(_publishers, m['publishedTopics'], 'publisherIds');
        merge(_subscribers, m['subscribedTopics'], 'subscriberIds');
        for (final t in (m['removedTopics'] as List? ?? const [])) {
          _publishers.remove(_ros('$t'));
          _subscribers.remove(_ros('$t'));
        }
        if (!_graphSeen.isCompleted) _graphSeen.complete();
    }
  }

  /// `pkg/srv/Name` for "pkg/srv/Name" or "pkg/Name".
  static String _serviceType(String type) {
    final p = type.split('/');
    return p.length == 2 ? '${p[0]}/srv/${p[1]}' : type;
  }

  /// A definition the bridge sends with a channel or service ("ros2msg": the message, then each
  /// dependency after a line of '=' and "MSG: pkg/msg/Name"). The bundled definitions stay first: the
  /// robot's are only for types the app does not know.
  /// Adds the dependencies, and the main definition under [type] when given; returns the main text.
  String? _learn(String? type, Object? schema, Object? encoding) {
    if (schema is! String || (encoding != null && encoding != 'ros2msg')) return null;
    final parts = schema.split(RegExp(r'\n=+\n'));
    void add(String t, String text) {
      if (!codec.interfaces.has(t)) codec.interfaces.add(t, text.trim());
    }
    if (type != null && schema.trim().isNotEmpty) add(type, parts.first);
    for (final part in parts.skip(1)) {
      final m = RegExp(r'^\s*MSG:\s*(\S+)\s*\n').firstMatch(part);
      if (m != null) add(canonicalType(m[1]!), part.substring(m.end));
    }
    return parts.first.trim();
  }

  void _onBinary(Uint8List data) {
    if (data.isEmpty) return;
    final view = ByteData.sublistView(data);
    switch (data[0]) {
      case 0x01: // message data: subscription id, receive time (ns), payload
        final sub = _subsById[view.getUint32(1, Endian.little)];
        final ch = sub == null ? null : _channels[sub.channel];
        if (sub == null || ch == null) return;
        final payload = Uint8List.sublistView(data, 13);
        final Map<String, dynamic> msg;
        try {
          msg = ch.encoding == 'json' ? jsonDecode(utf8.decode(payload)) as Map<String, dynamic>
              : codec.decode(ch.type, payload);
        } catch (e) {
          if (!sub.warned) {
            sub.warned = true;
            _error('Cannot read ${sub.topic} (${ch.type}): $e'
                '${codec.interfaces.has(ch.type) ? '' : '. Add its definition under Message definitions.'}');
          }
          return;
        }
        if (sub.throttle > 0) {
          sub.held = msg; // only the newest until the throttle period is over
        } else {
          _emit({'op': 'publish', 'topic': sub.topic, 'msg': msg});
        }
      case 0x03: // service call response: service id, call id, encoding, payload
        final callId = view.getUint32(5, Endian.little);
        final encodingLength = view.getUint32(9, Endian.little);
        final call = _calls.remove(callId);
        if (call == null) return;
        final payload = Uint8List.sublistView(data, 13 + encodingLength);
        try {
          call.$1.complete(codec.decode('${call.$2}_Response', payload));
        } catch (e) {
          call.$1.completeError(StateError('Cannot read the answer of ${call.$2}: $e'));
        }
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
      _emit({'op': 'publish', 'topic': sub.topic, 'msg': held});
    }
  }

  // ------------------------------------------------------------------------------ rosbridge ops

  @override
  void send(Map<String, dynamic> message) {
    if (_closed) throw StateError(lastError ?? 'Connection closed');
    if (!_ready.isCompleted) {
      // Before the hello, capabilities and services are unknown: deciding now would refuse to drive.
      _early.add(message);
      return;
    }
    try {
      switch (message['op']) {
        case 'subscribe':
          final topic = _ros('${message['topic']}');
          final sub = _subs.putIfAbsent(topic, () => _Sub(topic));
          sub.throttles[message['id'] as String?] = (message['throttle_rate'] as num?)?.toInt() ?? 0;
          final ch = _byTopic[topic];
          if (sub.id == null && ch != null) _subscribeChannel(sub, ch);
        case 'unsubscribe':
          final topic = _ros('${message['topic']}');
          final sub = _subs[topic];
          if (sub == null) return;
          if (message['id'] == null) {
            sub.throttles.clear();
          } else {
            sub.throttles.remove(message['id']);
          }
          if (sub.throttles.isEmpty) {
            _subs.remove(topic);
            final id = sub.id;
            if (id != null) {
              _subsById.remove(id);
              _sendJson({'op': 'unsubscribe', 'subscriptionIds': [id]});
            }
          }
        case 'advertise':
          _advertise(_ros('${message['topic']}'), canonicalType('${message['type']}'));
        case 'unadvertise':
          final ch = _clientChannels.remove(_ros('${message['topic']}'));
          if (ch != null) _sendJson({'op': 'unadvertise', 'channelIds': [ch.$1]});
        case 'publish':
          _publish(_ros('${message['topic']}'), (message['msg'] as Map?) ?? const {});
        case 'call_service':
          final service = '${message['service']}';
          call(service, Map<String, dynamic>.from((message['args'] as Map?) ?? const {})).then(
            (values) => _emit({'op': 'service_response', 'service': service, 'id': message['id'],
              'values': values, 'result': true}),
            onError: (Object e) => _emit({'op': 'service_response', 'service': service, 'id': message['id'],
              'values': '$e', 'result': false}),
          );
        case 'send_action_goal':
          _sendGoal(message);
        case 'cancel_action_goal':
          _cancelGoal(message);
        default:
          _error('Unsupported operation ${message['op']} on a Foxglove connection');
      }
    } catch (error) {
      _error('$error');
    }
  }

  void _subscribeChannel(_Sub sub, _Channel ch) {
    final id = _nextSub++;
    sub.id = id;
    sub.channel = ch.id;
    _subsById[id] = sub;
    _sendJson({'op': 'subscribe', 'subscriptions': [{'id': id, 'channelId': ch.id}]});
  }

  void _advertise(String topic, String type) {
    if (_clientChannels.containsKey(topic)) return;
    if (!capabilities.contains('clientPublish')) {
      throw StateError('The Foxglove bridge does not accept messages from clients (clientPublish is off), '
          'so this app cannot drive or send on $topic.');
    }
    final id = _nextClientChannel++;
    _clientChannels[topic] = (id, type);
    _sendJson({'op': 'advertise', 'channels': [
      {'id': id, 'topic': topic, 'encoding': 'cdr', 'schemaName': type},
    ]});
  }

  void _publish(String topic, Map msg) {
    if (!_clientChannels.containsKey(topic)) {
      final known = _byTopic[topic]?.type;
      if (known == null) throw StateError('Advertise $topic before publishing on it');
      _advertise(topic, known);
    }
    final (id, type) = _clientChannels[topic]!;
    final payload = codec.encode(type, msg);
    final frame = Uint8List(5 + payload.length);
    frame[0] = 0x01;
    ByteData.sublistView(frame).setUint32(1, id, Endian.little);
    frame.setRange(5, frame.length, payload);
    _outgoing(frame);
  }

  // ------------------------------------------------------------------------------ services

  @override
  Future<Map<String, dynamic>> call(String service, [Map<String, dynamic> args = const {}]) async {
    await ready;
    if (service.startsWith('/rosapi/')) {
      final name = service.substring(8);
      if (capabilities.contains('connectionGraph') &&
          const {'nodes', 'node_details', 'publishers', 'subscribers'}.contains(name)) {
        await _graphSeen.future.timeout(const Duration(seconds: 2), onTimeout: () {});
      }
      return _rosapi(name, args);
    }
    final s = _services[_ros(service)];
    if (s == null) throw StateError('Service ${_ros(service)} is not available through the Foxglove bridge');
    return _callService(s, args);
  }

  Future<Map<String, dynamic>> _callService(_Service s, Map args, {Duration? timeout}) {
    final callId = _nextCall++;
    final done = Completer<Map<String, dynamic>>();
    _calls[callId] = (done, s.type);
    final payload = codec.encode('${s.type}_Request', args);
    const encoding = [0x63, 0x64, 0x72]; // "cdr"
    final frame = Uint8List(13 + encoding.length + payload.length);
    final view = ByteData.sublistView(frame);
    frame[0] = 0x02;
    view.setUint32(1, s.id, Endian.little);
    view.setUint32(5, callId, Endian.little);
    view.setUint32(9, encoding.length, Endian.little);
    frame.setRange(13, 13 + encoding.length, encoding);
    frame.setRange(13 + encoding.length, frame.length, payload);
    _outgoing(frame);
    return done.future.timeout(timeout ?? this.timeout, onTimeout: () {
      _calls.remove(callId);
      throw StateError('No reply from ${s.name}');
    });
  }

  // ------------------------------------------------------------------------------ actions
  // Through the action's own services, when the bridge shows them (foxglove_bridge's include_hidden).
  // Without them, navigation uses the goal topic instead.

  void _sendGoal(Map m) {
    final action = _ros('${m['action']}');
    final sendGoal = _services['$action/_action/send_goal'];
    final uuid = Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
    final goal = _Goal(m['id'] as String?, action, uuid);
    void fail(Object error) => _emit({'op': 'action_result', 'id': goal.id, 'action': action,
      'values': '$error', 'status': 0, 'result': false});
    if (sendGoal == null || !sendGoal.type.endsWith('_SendGoal')) {
      fail(StateError('Action $action is not available through the Foxglove bridge'));
      return;
    }
    final base = sendGoal.type.substring(0, sendGoal.type.length - '_SendGoal'.length);
    _goals[goal.id ?? action] = goal;
    () async {
      try {
        final accepted = await _callService(sendGoal, {'goal_id': {'uuid': uuid}, 'goal': m['args'] ?? const {}});
        if (accepted['accepted'] != true) throw StateError('Goal was rejected');
        final getResult = _services['$action/_action/get_result'];
        if (getResult == null) throw StateError('Action $action has no result service');
        final result = await _callService(_Service(getResult.id, getResult.name, '${base}_GetResult'),
            {'goal_id': {'uuid': uuid}}, timeout: const Duration(hours: 1));
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

  void _cancelGoal(Map m) {
    final action = _ros('${m['action']}');
    final goal = _goals[m['id'] ?? action] ?? _goals.values.where((g) => g.action == action).firstOrNull;
    final cancel = _services['$action/_action/cancel_goal'];
    if (goal == null || cancel == null) return;
    _callService(cancel, {
      'goal_info': {'goal_id': {'uuid': goal.uuid}, 'stamp': {'sec': 0, 'nanosec': 0}},
    }).catchError((Object e) {
      _error('Could not cancel the goal: $e');
      return <String, dynamic>{};
    });
  }

  // ------------------------------------------------------------------------------ rosapi

  Map<String, dynamic> _rosapi(String name, Map args) {
    List<String> services() => _services.keys.toList()..sort();
    switch (name) {
      case 'topics':
        final names = _byTopic.keys.toList()..sort();
        return {'topics': names, 'types': [for (final n in names) _byTopic[n]!.type]};
      case 'topic_type':
        return {'type': _byTopic[_ros('${args['topic']}')]?.type ?? ''};
      case 'publishers':
        return {'publishers': (_publishers[_ros('${args['topic']}')] ?? const <String>{}).toList()};
      case 'subscribers':
        return {'subscribers': (_subscribers[_ros('${args['topic']}')] ?? const <String>{}).toList()};
      case 'nodes':
        return {'nodes': ({for (final s in [..._publishers.values, ..._subscribers.values]) ...s}.toList()..sort())};
      case 'node_details':
        final node = '${args['node']}';
        List<String> of(Map<String, Set<String>> m) => [for (final e in m.entries) if (e.value.contains(node)) e.key]..sort();
        return {'publishing': of(_publishers), 'subscribing': of(_subscribers), 'services': <String>[]};
      case 'services':
        return {'services': services()};
      case 'service_type':
        return {'type': _services[_ros('${args['service']}')]?.type ?? ''};
      case 'action_servers':
        const suffix = '/_action/send_goal';
        return {'action_servers': [for (final s in services()) if (s.endsWith(suffix)) s.substring(0, s.length - suffix.length)]};
      case 'interfaces':
        return {'interfaces': codec.interfaces.allInterfaces.toList()..sort()};
      case 'message_details':
        return {'typedefs': rosapiTypedefs(codec.interfaces, '${args['type']}')};
      case 'service_request_details' || 'service_response_details':
        final t = '${args['type']}'.split('/');
        final srv = t.length == 2 ? '${t[0]}/srv/${t[1]}' : '${args['type']}';
        return {'typedefs': rosapiTypedefs(codec.interfaces,
            '$srv${name == 'service_request_details' ? '_Request' : '_Response'}')};
    }
    throw StateError('/rosapi/$name is not available on a Foxglove connection');
  }

  // ------------------------------------------------------------------------------ lifecycle

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _flush.cancel();
    _helloTimer?.cancel();
    _socket.cancel();
    for (final c in _calls.values) {
      if (!c.$1.isCompleted) c.$1.completeError(StateError('Connection closed'));
    }
    _calls.clear();
    if (!_ready.isCompleted) _ready.completeError(StateError(lastError ?? 'Connection closed'));
    _ready.future.catchError((_) {});
    if (!_messages.isClosed) _messages.close();
    onClose?.call();
  }
}
