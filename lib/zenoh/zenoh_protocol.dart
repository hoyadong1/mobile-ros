/// How ROS 2's rmw_zenoh (Jazzy, zenoh 1.8) lays a robot out on Zenoh, as observed on a running Nav2
/// robot. Pure functions, no I/O.
///
/// Graph: every node and endpoint holds a liveliness token
///   `@ros2_lv/<domain>/<zid>/<node id>/<entity id>/<kind>/<enclave>/<namespace>/<node>`
///   `[/<name>/<dds type>/<type hash>/<qos>]`, kind NN (node), MP/MS (publisher/subscription),
///   SS/SC (service server/client); names have their slashes written as `%`.
/// Data: `<domain>/<name without the leading slash>/<dds type>/<type hash>`, payload = CDR with its
///   4-byte header, attachment = sequence number (int64 LE) + source time in ns (int64 LE) + 16 + a
///   16-byte GID. Service calls are queries on the same key shape, with the same attachment.
library;

import 'dart:math' as math;
import 'dart:typed_data';
import '../dds/ros_interfaces.dart' show rosTypeFromDds;

enum ZenohEntityKind { node, publisher, subscription, serviceServer, serviceClient }

const _kinds = {
  'NN': ZenohEntityKind.node,
  'MP': ZenohEntityKind.publisher,
  'MS': ZenohEntityKind.subscription,
  'SS': ZenohEntityKind.serviceServer,
  'SC': ZenohEntityKind.serviceClient,
};

/// `%robot1%odom` → `/robot1/odom`; `%` → `/`.
String _unmangle(String s) => s.replaceAll('%', '/');

/// One node or endpoint of the robot's graph, read from its liveliness token.
class ZenohEntity {
  const ZenohEntity({required this.token, required this.domain, required this.zid, required this.nodeId,
      required this.entityId, required this.kind, required this.namespace, required this.nodeName,
      this.name = '', this.ddsType = '', this.typeHash = '', this.qos = ''});

  /// Parses a liveliness token key; null if it is not an rmw_zenoh token.
  static ZenohEntity? parse(String token) {
    final p = token.split('/');
    if (p.length < 9 || p[0] != '@ros2_lv') return null;
    final kind = _kinds[p[5]];
    final domain = int.tryParse(p[1]);
    if (kind == null || domain == null) return null;
    if (kind != ZenohEntityKind.node && p.length < 13) return null;
    return ZenohEntity(
      token: token, domain: domain, zid: p[2], nodeId: p[3], entityId: p[4], kind: kind,
      namespace: _unmangle(p[7]), nodeName: p[8],
      name: kind == ZenohEntityKind.node ? '' : _unmangle(p[9]),
      ddsType: kind == ZenohEntityKind.node ? '' : p[10],
      typeHash: kind == ZenohEntityKind.node ? '' : p[11],
      qos: kind == ZenohEntityKind.node ? '' : p.sublist(12).join('/'),
    );
  }

  final String token;
  final int domain;
  final String zid, nodeId, entityId;
  final ZenohEntityKind kind;
  /// `/` or e.g. `/robot1`.
  final String namespace;
  final String nodeName;
  /// Topic or service name with its leading slash, e.g. `/odom`; empty for nodes.
  final String name;
  /// e.g. `nav_msgs::msg::dds_::Odometry_`.
  final String ddsType;
  /// e.g. `RIHS01_3cc9…`; part of the data key, so it must match exactly.
  final String typeHash;
  final String qos;

  /// Fully qualified node name, e.g. `/amcl` or `/robot1/amcl`.
  String get node => namespace == '/' ? '/$nodeName' : '$namespace/$nodeName';

  /// ROS type, e.g. `nav_msgs/msg/Odometry` (services: `pkg/srv/X`, action parts: `pkg/action/X_SendGoal`).
  String? get rosType => rosTypeFromDds(ddsType);

  /// Transient-local durability (latched topics such as /map): second field of the QoS string.
  bool get transientLocal {
    final fields = qos.split(':');
    return fields.length > 1 && fields[1] == '1';
  }

  /// The key data (or service calls) for this endpoint travel on.
  String get dataKey => zenohDataKey(domain, name, ddsType, typeHash);

  /// The node's identity (what the graph keys nodes by).
  String get nodeKey => '$zid/$nodeId';
}

/// `<domain>/<name without leading slash>/<dds type>/<hash>`.
String zenohDataKey(int domain, String name, String ddsType, String typeHash) =>
    '$domain/${name.startsWith('/') ? name.substring(1) : name}/$ddsType/$typeHash';

/// Matches the data of [name] whatever its type and hash (exactly two more chunks, so `/odom` does
/// not also match `/odom/filtered`).
String zenohTopicSelector(int domain, String name) =>
    '$domain/${name.startsWith('/') ? name.substring(1) : name}/*/*';

/// The DDS type name and hash from a data key, e.g. for a sample received through a selector.
(String ddsType, String typeHash)? zenohKeyType(String key) {
  final p = key.split('/');
  if (p.length < 4) return null;
  return (p[p.length - 2], p[p.length - 1]);
}

/// The attachment rmw_zenoh puts on every message and service call.
Uint8List zenohAttachment(int sequence, int timeNs, Uint8List gid) {
  if (gid.length != 16) throw ArgumentError('GID must be 16 bytes');
  final b = ByteData(33)
    ..setInt64(0, sequence, Endian.little)
    ..setInt64(8, timeNs, Endian.little)
    ..setUint8(16, 16);
  final out = b.buffer.asUint8List();
  out.setRange(17, 33, gid);
  return out;
}

/// Sequence number, time and GID from an attachment; null if it is not rmw_zenoh's layout.
(int sequence, int timeNs, Uint8List gid)? parseZenohAttachment(Uint8List a) {
  if (a.length < 17) return null;
  final b = ByteData.sublistView(a);
  final n = b.getUint8(16);
  if (a.length < 17 + n) return null;
  return (b.getInt64(0, Endian.little), b.getInt64(8, Endian.little), Uint8List.fromList(a.sublist(17, 17 + n)));
}

/// 16 random bytes, for a publisher or client GID and for action goal ids.
Uint8List randomId(math.Random random) => Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));

/// The robot's graph, kept up to date from liveliness tokens appearing and disappearing.
class ZenohGraph {
  final _entities = <String, ZenohEntity>{};

  Iterable<ZenohEntity> get entities => _entities.values;
  bool get isEmpty => _entities.isEmpty;

  /// Applies a token event; returns whether the graph changed.
  bool apply(String token, {required bool alive}) {
    if (!alive) return _entities.remove(token) != null;
    final e = ZenohEntity.parse(token);
    if (e == null || _entities.containsKey(token)) return false;
    _entities[token] = e;
    return true;
  }

  Iterable<ZenohEntity> ofKind(ZenohEntityKind kind) => _entities.values.where((e) => e.kind == kind);

  Iterable<ZenohEntity> endpointsOf(String name, {Set<ZenohEntityKind>? kinds}) =>
      _entities.values.where((e) => e.name == name && (kinds == null || kinds.contains(e.kind)));

  /// A publisher or subscription on [topic] (any will do for the type and hash), preferring publishers.
  ZenohEntity? topicEndpoint(String topic) {
    ZenohEntity? sub;
    for (final e in endpointsOf(topic)) {
      if (e.kind == ZenohEntityKind.publisher) return e;
      if (e.kind == ZenohEntityKind.subscription) sub ??= e;
    }
    return sub;
  }

  ZenohEntity? serviceServer(String service) =>
      endpointsOf(service, kinds: const {ZenohEntityKind.serviceServer}).firstOrNull;

  List<String> get nodeNames => {for (final e in ofKind(ZenohEntityKind.node)) e.node}.toList()..sort();
}
