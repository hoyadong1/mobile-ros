import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'navigation_goal.dart' show RosVersion;
import 'ros_client.dart';

/// Parameters on the robot: the few settings people change most, with plain names, and every
/// parameter of every node for the rest. Changes take effect at once and last until the node restarts
/// (they are not written into the robot's configuration files).

/// A parameter value of either ROS version. ROS 2 types follow rcl_interfaces/ParameterType.
class ParamValue {
  const ParamValue(this.type, this.value);

  static const notSet = 0, boolean = 1, integer = 2, double_ = 3, string = 4, byteArray = 5, boolArray = 6,
      integerArray = 7, doubleArray = 8, stringArray = 9;

  final int type;
  final Object? value;

  bool get isSet => type != notSet;
  bool get isNumber => type == integer || type == double_;
  bool get isArray => type >= byteArray;

  /// From rcl_interfaces/ParameterValue as rosbridge sends it.
  factory ParamValue.fromRos2(Map v) {
    final type = (v['type'] as num?)?.toInt() ?? 0;
    final value = switch (type) {
      boolean => v['bool_value'],
      integer => (v['integer_value'] as num?)?.toInt(),
      double_ => (v['double_value'] as num?)?.toDouble(),
      string => v['string_value'],
      byteArray => v['byte_array_value'],
      boolArray => v['bool_array_value'],
      integerArray => [for (final x in (v['integer_array_value'] as List? ?? const [])) (x as num).toInt()],
      doubleArray => [for (final x in (v['double_array_value'] as List? ?? const [])) (x as num).toDouble()],
      stringArray => v['string_array_value'],
      _ => null,
    };
    return ParamValue(type, value);
  }

  /// From a ROS 1 parameter server value (rosapi returns it as JSON).
  factory ParamValue.fromJson(Object? v) => switch (v) {
    bool() => ParamValue(boolean, v),
    int() => ParamValue(integer, v),
    double() => ParamValue(double_, v),
    String() => ParamValue(string, v),
    List() when v.every((e) => e is num) => ParamValue(doubleArray, [for (final e in v) (e as num).toDouble()]),
    List() => ParamValue(stringArray, [for (final e in v) '$e']),
    null => const ParamValue(notSet, null),
    _ => ParamValue(string, jsonEncode(v)), // a nested namespace (dict): shown, not edited
  };

  Map<String, dynamic> toRos2() => {
    'type': type,
    if (type == boolean) 'bool_value': value,
    if (type == integer) 'integer_value': value,
    if (type == double_) 'double_value': value,
    if (type == string) 'string_value': value,
    if (type == byteArray) 'byte_array_value': value,
    if (type == boolArray) 'bool_array_value': value,
    if (type == integerArray) 'integer_array_value': value,
    if (type == doubleArray) 'double_array_value': value,
    if (type == stringArray) 'string_array_value': value,
  };

  /// A number view: the value itself, or element [index] of a numeric array.
  double? number([int? index]) {
    final v = value;
    if (index != null) return v is List && index < v.length && v[index] is num ? (v[index] as num).toDouble() : null;
    return v is num ? v.toDouble() : null;
  }

  /// This value with a number set (into element [index] of an array), keeping the type.
  ParamValue withNumber(double n, [int? index]) {
    if (index != null) {
      final list = List<Object?>.of(value as List);
      list[index] = type == integerArray ? n.round() : n;
      return ParamValue(type, list);
    }
    return ParamValue(type, type == integer ? n.round() : n);
  }

  String get typeName => const ['not set', 'true/false', 'whole number', 'number', 'text', 'bytes', 'true/false list',
    'number list', 'number list', 'text list'][type.clamp(0, 9)];

  String display() {
    final v = value;
    if (v is double) return _trim(v);
    if (v is List) return '[${v.map((e) => e is double ? _trim(e) : '$e').join(', ')}]';
    if (v is String) return v.isEmpty ? '(empty)' : v;
    return '$v';
  }

  static String _trim(double v) {
    var s = v.toStringAsFixed(4);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    return s.endsWith('.') ? '${s}0' : s;
  }

  @override
  bool operator ==(Object other) => other is ParamValue && other.type == type &&
      jsonEncode(other.value) == jsonEncode(value);

  @override
  int get hashCode => Object.hash(type, jsonEncode(value));
}

/// Where a common setting lives: a node's parameter (ROS 2), or a parameter server name (ROS 1, [node]
/// empty), optionally one element of an array.
class ParamTarget {
  const ParamTarget(this.node, this.name, {this.index});
  final String node;
  final String name;
  final int? index;

  String get id => '$node:$name${index == null ? '' : '[$index]'}';
}

/// A setting people change often, in plain words. One setting may set several parameters together
/// (a top speed is capped by the path follower and by the velocity smoother).
class CommonSetting {
  const CommonSetting({required this.key, required this.label, required this.help, required this.unit,
    required this.min, required this.max, required this.step, this.scale = 1, required this.ros2,
    this.ros1 = const []});
  final String key, label, help, unit;
  /// Range and step in shown units (after [scale]).
  final double min, max, step;
  /// Shown = stored × scale (radians shown as degrees).
  final double scale;
  final List<ParamTarget> ros2, ros1;

  int get decimals => step >= 1 ? 0 : step >= 0.1 ? 1 : 2;
  String format(double shown) => '${shown.toStringAsFixed(decimals)} $unit';
}

const _deg = 180 / math.pi;

const commonSettings = [
  CommonSetting(key: 'speed', label: 'Top speed', unit: 'm/s', min: 0.05, max: 1.5, step: 0.01,
    help: 'When it drives on its own.',
    ros2: [
      ParamTarget('/controller_server', 'FollowPath.max_vel_x'),
      ParamTarget('/controller_server', 'FollowPath.max_speed_xy'),
      ParamTarget('/controller_server', 'FollowPath.desired_linear_vel'),
      ParamTarget('/velocity_smoother', 'max_velocity', index: 0),
    ],
    ros1: [
      ParamTarget('', '/move_base/DWAPlannerROS/max_vel_x'),
      ParamTarget('', '/move_base/DWAPlannerROS/max_vel_trans'),
      ParamTarget('', '/move_base/TrajectoryPlannerROS/max_vel_x'),
    ]),
  CommonSetting(key: 'turn', label: 'Turning speed', unit: '°/s', min: 10, max: 180, step: 1, scale: _deg,
    help: 'Turning on the spot, on its own.',
    ros2: [
      ParamTarget('/controller_server', 'FollowPath.max_vel_theta'),
      ParamTarget('/controller_server', 'FollowPath.rotate_to_heading_angular_vel'),
      ParamTarget('/velocity_smoother', 'max_velocity', index: 2),
    ],
    ros1: [
      ParamTarget('', '/move_base/DWAPlannerROS/max_vel_theta'),
      ParamTarget('', '/move_base/DWAPlannerROS/max_rot_vel'),
      ParamTarget('', '/move_base/TrajectoryPlannerROS/max_vel_theta'),
    ]),
  CommonSetting(key: 'clearance', label: 'Distance from obstacles', unit: 'm', min: 0.05, max: 1.5, step: 0.01,
    help: 'Larger is safer; too large and it will not fit through gaps.',
    ros2: [
      ParamTarget('/local_costmap/local_costmap', 'inflation_layer.inflation_radius'),
      ParamTarget('/global_costmap/global_costmap', 'inflation_layer.inflation_radius'),
    ],
    ros1: [
      ParamTarget('', '/move_base/local_costmap/inflation_layer/inflation_radius'),
      ParamTarget('', '/move_base/global_costmap/inflation_layer/inflation_radius'),
      ParamTarget('', '/move_base/local_costmap/inflation_radius'),
      ParamTarget('', '/move_base/global_costmap/inflation_radius'),
    ]),
  CommonSetting(key: 'radius', label: 'Robot size (radius)', unit: 'm', min: 0.05, max: 1.0, step: 0.01,
    help: 'Too small clips corners; too big will not fit.',
    ros2: [
      ParamTarget('/local_costmap/local_costmap', 'robot_radius'),
      ParamTarget('/global_costmap/global_costmap', 'robot_radius'),
    ],
    ros1: [
      ParamTarget('', '/move_base/local_costmap/robot_radius'),
      ParamTarget('', '/move_base/global_costmap/robot_radius'),
    ]),
  CommonSetting(key: 'arrive', label: 'Close enough to arrive', unit: 'm', min: 0.02, max: 1.0, step: 0.01,
    help: 'How near counts as arrived.',
    ros2: [
      ParamTarget('/controller_server', 'general_goal_checker.xy_goal_tolerance'),
      ParamTarget('/controller_server', 'goal_checker.xy_goal_tolerance'),
    ],
    ros1: [
      ParamTarget('', '/move_base/DWAPlannerROS/xy_goal_tolerance'),
      ParamTarget('', '/move_base/TrajectoryPlannerROS/xy_goal_tolerance'),
    ]),
  CommonSetting(key: 'heading', label: 'Heading accuracy on arrival', unit: '°', min: 2, max: 180, step: 1, scale: _deg,
    help: 'How exactly it must face the chosen way.',
    ros2: [
      ParamTarget('/controller_server', 'general_goal_checker.yaw_goal_tolerance'),
      ParamTarget('/controller_server', 'goal_checker.yaw_goal_tolerance'),
    ],
    ros1: [
      ParamTarget('', '/move_base/DWAPlannerROS/yaw_goal_tolerance'),
      ParamTarget('', '/move_base/TrajectoryPlannerROS/yaw_goal_tolerance'),
    ]),
  CommonSetting(key: 'sight', label: 'Obstacle sensing distance', unit: 'm', min: 0.5, max: 10, step: 0.1,
    help: 'How far it looks for obstacles.',
    ros2: [
      ParamTarget('/local_costmap/local_costmap', 'voxel_layer.scan.obstacle_max_range'),
      ParamTarget('/local_costmap/local_costmap', 'obstacle_layer.scan.obstacle_max_range'),
    ]),
];

/// Reads and writes parameters over rosbridge: each node's parameter services on ROS 2, the parameter
/// server through rosapi on ROS 1.
class ParamClient {
  ParamClient(this.ros, this.version, {this.namespace = '', this.timeout = const Duration(seconds: 4)});
  final RosClient ros;
  final RosVersion version;
  final String namespace;
  final Duration timeout;

  bool get ros1 => version == RosVersion.ros1;
  String _node(String node) => node.startsWith(namespace) || namespace.isEmpty ? node : '$namespace$node';

  /// Values of [names] on [node] (ROS 1: [node] is ignored, names are full). Missing ones are not set.
  Future<Map<String, ParamValue>> get(String node, List<String> names) async {
    if (names.isEmpty) return {};
    if (ros1) {
      final out = <String, ParamValue>{};
      for (final n in names) {
        try {
          final r = await ros.callService('/rosapi/get_param', {'name': n, 'default': ''}).timeout(timeout);
          final raw = r['value'];
          out[n] = raw is String && raw.isNotEmpty ? ParamValue.fromJson(jsonDecode(raw)) : const ParamValue(0, null);
        } catch (_) {
          out[n] = const ParamValue(0, null);
        }
      }
      return out;
    }
    final r = await _retry(() => ros.callService('${_node(node)}/get_parameters', {'names': names}));
    final values = r['values'] as List? ?? const [];
    // A node answers an empty list when any name is not declared: then each name is asked alone.
    if (values.length != names.length && names.length > 1) {
      final out = <String, ParamValue>{};
      for (final n in names) {
        out.addAll(await get(node, [n]));
      }
      return out;
    }
    return {for (var i = 0; i < names.length; i++) names[i]: i < values.length ? ParamValue.fromRos2(values[i] as Map) : const ParamValue(0, null)};
  }

  /// Sets values on [node]; returns the names that failed with the robot's reason.
  Future<Map<String, String>> set(String node, Map<String, ParamValue> values) async {
    final failed = <String, String>{};
    if (values.isEmpty) return failed;
    if (ros1) {
      for (final e in values.entries) {
        try {
          await ros.callService('/rosapi/set_param', {'name': e.key, 'value': jsonEncode(e.value.value)}).timeout(timeout);
        } catch (err) {
          failed[e.key] = '$err';
        }
      }
      return failed;
    }
    final names = values.keys.toList();
    final r = await _retry(() => ros.callService('${_node(node)}/set_parameters', {
      'parameters': [for (final n in names) {'name': n, 'value': values[n]!.toRos2()}],
    }));
    final results = r['results'] as List? ?? const [];
    for (var i = 0; i < names.length; i++) {
      final res = i < results.length ? results[i] as Map : const {};
      if (res['successful'] != true) {
        final reason = '${res['reason'] ?? ''}'.trim();
        failed[names[i]] = reason.isEmpty ? 'The robot refused the value.' : reason;
      }
    }
    return failed;
  }

  /// Asks once more when there is no answer: with rosbridge on ROS 2 the first call to a node's
  /// service is sometimes answered before the bridge's new client is ready, and the reply is lost
  /// (the node logs "failed to send response"). Setting a parameter twice to the same value is harmless.
  Future<Map<String, dynamic>> _retry(Future<Map<String, dynamic>> Function() call) async {
    try {
      return await call().timeout(timeout);
    } on TimeoutException {
      return call().timeout(timeout);
    }
  }

  /// Every parameter name of [node] (ROS 1: every name on the parameter server).
  Future<List<String>> names(String node) async {
    if (ros1) {
      final r = await ros.callService('/rosapi/get_param_names').timeout(timeout);
      return [for (final n in (r['names'] as List? ?? const [])) '$n']..sort();
    }
    final r = await _retry(() => ros.callService('${_node(node)}/list_parameters', {'prefixes': <String>[], 'depth': 0}));
    return [for (final n in ((r['result'] as Map?)?['names'] as List? ?? const [])) '$n']..sort();
  }
}

/// A common setting as found on this robot: the parameters that exist, their values, the shown value.
class FoundSetting {
  FoundSetting(this.setting, this.values);
  final CommonSetting setting;
  /// The targets that exist on the robot, with their current values.
  final Map<ParamTarget, ParamValue> values;

  /// Every value behind this setting, in shown units (several when the parameters disagree).
  List<double> get allShown => [
    for (final e in values.entries)
      if (e.value.number(e.key.index) case final n?) n * setting.scale,
  ];

  /// The parameters behind this setting hold different values (e.g. a velocity smoother capping the
  /// path follower lower): applying sets them all to one.
  bool get mixed {
    final v = allShown;
    return v.length > 1 && v.any((x) => (x - v.first).abs() > setting.step / 2);
  }

  /// The shown value (from the first target that has a number).
  double? get shown {
    for (final e in values.entries) {
      final n = e.value.number(e.key.index);
      if (n != null) return n * setting.scale;
    }
    return null;
  }
}

/// Looks for each common setting on the robot (only nodes that are running are asked). Nodes that did
/// not answer are added to [silent], so the screen can say some settings may be missing.
Future<List<FoundSetting>> findCommonSettings(ParamClient client, List<String> runningNodes,
    {Set<String>? silent}) async {
  final found = <FoundSetting>[];
  final nodes = runningNodes.toSet();
  // Ask each node once for everything it might have.
  final wanted = <String, Set<String>>{};
  for (final s in commonSettings) {
    for (final t in client.ros1 ? s.ros1 : s.ros2) {
      if (!client.ros1 && !nodes.contains(client._node(t.node))) continue;
      (wanted[t.node] ??= {}).add(t.name);
    }
  }
  final values = <String, Map<String, ParamValue>>{};
  // ROS 2: ask only for names the node has (asking for an undeclared one empties the whole answer).
  Future<Map<String, ParamValue>> read(String node, Set<String> names) async {
    if (client.ros1) return client.get(node, names.toList());
    final has = (await client.names(node)).toSet();
    final present = names.where(has.contains).toList();
    return present.isEmpty ? <String, ParamValue>{} : client.get(node, present);
  }
  await Future.wait([
    for (final e in wanted.entries)
      read(e.key, e.value).then((v) => values[e.key] = v).catchError((_) {
        silent?.add(e.key);
        return <String, ParamValue>{};
      }),
  ]);
  for (final s in commonSettings) {
    final have = <ParamTarget, ParamValue>{};
    for (final t in client.ros1 ? s.ros1 : s.ros2) {
      final v = values[t.node]?[t.name];
      if (v != null && v.isSet && v.number(t.index) != null) have[t] = v;
    }
    if (have.isNotEmpty) found.add(FoundSetting(s, have));
  }
  return found;
}

/// Sets [shown] (in the setting's units) on every parameter behind [found]. Returns failures by target.
Future<Map<ParamTarget, String>> applySetting(ParamClient client, FoundSetting found, double shown) async {
  final stored = shown / found.setting.scale;
  final targets = <String, List<ParamTarget>>{};
  for (final t in found.values.keys) {
    (targets[t.node] ??= []).add(t);
  }
  final byNode = <String, Map<String, ParamValue>>{};
  final targetOf = <String, ParamTarget>{};
  for (final e in targets.entries) {
    // Read again first: an array (velocity_smoother max_velocity) may hold another setting's element
    // that changed since this one was found.
    Map<String, ParamValue> fresh = const {};
    try {
      fresh = await client.get(e.key, {for (final t in e.value) t.name}.toList());
    } catch (_) {}
    final out = byNode[e.key] = {};
    for (final t in e.value) {
      final current = out[t.name] ?? (fresh[t.name]?.isSet == true ? fresh[t.name]! : found.values[t]!);
      out[t.name] = current.withNumber(stored, t.index);
      targetOf['${t.node}:${t.name}'] = t;
    }
  }
  final failed = <ParamTarget, String>{};
  for (final e in byNode.entries) {
    try {
      final f = await client.set(e.key, e.value);
      for (final n in f.entries) {
        failed[targetOf['${e.key}:${n.key}']!] = n.value;
      }
    } catch (err) {
      for (final n in e.value.keys) {
        failed[targetOf['${e.key}:$n']!] = err is TimeoutException ? 'The robot did not answer.' : '$err';
      }
    }
  }
  return failed;
}
