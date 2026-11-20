import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Which saved robot an address belongs to, so a robot keeps its name, memory, places, routines and
/// settings when it is reached another way: a new IP from the router (DHCP), Zenoh instead of
/// rosbridge, or remote access instead of the local network.
///
/// Everything per robot is saved under a store key. A robot's store key is the first address it was
/// seen at (`host:port`, as before this existed, so no saved data moves). Another address is linked to
/// it once the person confirms it is the same robot; the app suggests that when the robot's ROS graph
/// (its node names) matches one seen before at another address.
class RobotIdentity {
  RobotIdentity._(this._aliases, this._robots, this._distinct);

  static const _key = 'robot_identity';

  /// Address -> store key, for addresses linked to a robot first seen elsewhere.
  final Map<String, String> _aliases;
  /// Store key -> {fp: fingerprint, label, last: last address}.
  final Map<String, Map<String, String>> _robots;
  /// "address|store key" pairs the person said are different robots: not asked again.
  final Set<String> _distinct;

  static Future<RobotIdentity> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final j = raw == null ? const {} : jsonDecode(raw) as Map;
      return RobotIdentity._(
        {for (final e in (j['aliases'] as Map? ?? const {}).entries) '${e.key}': '${e.value}'},
        {for (final e in (j['robots'] as Map? ?? const {}).entries)
          '${e.key}': {for (final f in (e.value as Map).entries) '${f.key}': '${f.value}'}},
        {for (final d in j['distinct'] as List? ?? const []) '$d'},
      );
    } catch (_) {
      return RobotIdentity._({}, {}, {});
    }
  }

  Future<void> _save() async => (await SharedPreferences.getInstance()).setString(_key, jsonEncode({
    'aliases': _aliases, 'robots': _robots, 'distinct': _distinct.toList(),
  }));

  /// The store key for [address] (the address itself unless linked to a robot first seen elsewhere).
  String storeKeyFor(String address) => _aliases[address] ?? address;

  /// A robot seen before at another address whose ROS graph matches [fingerprint], unless the person
  /// said it is a different one. Null when none, or when [address] is already that robot's.
  ({String storeKey, String label, String last})? match(String fingerprint, String address) {
    if (fingerprint.isEmpty) return null;
    final mine = storeKeyFor(address);
    for (final e in _robots.entries) {
      if (e.key == mine || e.value['fp'] != fingerprint || _distinct.contains('$address|${e.key}')) continue;
      return (storeKey: e.key, label: e.value['label'] ?? '', last: e.value['last'] ?? e.key);
    }
    return null;
  }

  /// Notes what the robot under [storeKey] looks like and where it was last seen.
  Future<void> remember(String storeKey, {required String fingerprint, required String label, required String address}) async {
    _robots[storeKey] = {'fp': fingerprint, 'label': label, 'last': address};
    await _save();
  }

  /// [address] is the robot saved under [storeKey] (the person said so).
  Future<void> link(String address, String storeKey) async {
    if (address == storeKey) {
      _aliases.remove(address);
    } else {
      _aliases[address] = storeKey;
    }
    await _save();
  }

  /// [address] is not the robot saved under [storeKey]: do not suggest it again.
  Future<void> markDistinct(String address, String storeKey) async {
    _distinct.add('$address|$storeKey');
    await _save();
  }

  /// The robot's node names, without the ones that come and go with tools and connections (rosbridge,
  /// rosapi, this app, the ROS command line, viewers): what is left identifies the robot's own software.
  static String fingerprint(List<String> nodes) {
    final own = [
      for (final n in nodes)
        if (!RegExp(r'rosbridge|rosapi|mobile_ros|_ros2cli|ros2cli|daemon|rviz|rqt|launch_ros|transform_listener_impl|'
            r'foxglove|_[0-9a-f]{8,}$|\d{6,}', caseSensitive: false).hasMatch(n)) n,
    ]..sort();
    // Too few nodes say little about which robot it is.
    return own.length < 3 ? '' : own.join(',');
  }
}
