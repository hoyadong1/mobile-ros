import 'dart:async';
import 'dart:io' show Directory;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import '../map_geometry.dart';
import '../mapping.dart';
import '../navigation_goal.dart';
import '../places.dart';
import '../relocalize.dart';
import '../robot_capabilities.dart';
import '../robot_log.dart';
import '../robot_session.dart';
import '../ros_client.dart';
import '../ros_connection.dart';
import '../sensors.dart';
import 'skill.dart';

/// What the assistant can find out and look after beyond driving: the robot's health (battery, log
/// problems), where it is (matching the laser to the map), saving the current spot as a place, and
/// saving a map while mapping. Nothing here moves the robot.

/// Which of these this robot supports right now.
class RobotAbilities {
  const RobotAbilities({this.localize = false, this.savePlace = false, this.saveMap = false, this.battery});
  final bool localize, savePlace, saveMap;
  final String? battery;
  static const none = RobotAbilities();
}

/// The first message on [topic] within [timeout], or null.
Future<Map<String, dynamic>?> readOnce(RosClient ros, String topic, {String? type,
    Duration timeout = const Duration(seconds: 3)}) async {
  try {
    return await ros.subscribe(topic, type: type).first.timeout(timeout);
  } catch (_) {
    return null;
  }
}

class RobotTools {
  RobotTools({required this.ros, required this.connection, required this.capabilities, this.log, this.places,
    this.namespace = '', this.mapFolder});

  factory RobotTools.forSession(RobotSession s) => RobotTools(ros: s.ros, connection: s.connection,
      capabilities: s.capabilities, log: s.robotLog, places: s.places, namespace: s.namespace);

  final RosClient ros;
  final RosConnection connection;
  final Future<RobotCapabilities> Function() capabilities;
  final RobotLog? log;
  final PlaceBook? places;
  final String namespace;
  /// Where saved maps go on the phone (default: the app's documents folder, `maps/`).
  final Future<Directory> Function()? mapFolder;

  RobotAbilities abilities = RobotAbilities.none;
  RosVersion _version = RosVersion.ros2;
  String? _scan, _map;
  MappingSetup? _mapping;
  DateTime? _refreshedAt;

  /// Finds out what this robot offers (at most every 20 s; cheap otherwise).
  Future<void> refresh({bool force = false}) async {
    final at = _refreshedAt;
    if (!force && at != null && DateTime.now().difference(at) < const Duration(seconds: 20)) return;
    _refreshedAt = DateTime.now();
    try {
      final caps = await capabilities();
      _version = caps.rosVersion;
      final battery = caps.topicsOfType('sensor_msgs/BatteryState').firstOrNull;
      _scan = await caps.pick('sensor_msgs/LaserScan', 'scan');
      _map = await caps.pick('nav_msgs/OccupancyGrid', 'map');
      final mapperRunning = caps.nodes.any((n) => RegExp(r'(slam|cartographer|gmapping|hector|rtabmap)').hasMatch(n));
      _mapping = mapperRunning ? await detectMapping(connection, caps.nodes, namespace: namespace) : null;
      final amcl = caps.nodes.any((n) => n.endsWith('/amcl'));
      abilities = RobotAbilities(
        battery: battery,
        localize: _map != null && _scan != null && amcl,
        savePlace: _map != null && places != null,
        saveMap: _mapping?.mapping == true && _map != null,
      );
    } catch (_) {
      abilities = RobotAbilities(savePlace: places != null && _map != null);
    }
  }

  // ---- check_robot ------------------------------------------------------------------------

  /// Battery and the log's recent problems, as one report.
  Future<SkillResult> checkRobot() async {
    final data = <String, Object?>{};
    final parts = <String>[];
    final battery = abilities.battery;
    if (battery != null) {
      final msg = await readOnce(ros, battery);
      if (msg != null) {
        final s = decodeSensor(SensorKind.battery, msg);
        data['battery'] = s.headline;
        if (s.warning != null) data['battery_warning'] = s.warning;
        parts.add('Battery: ${s.headline}${s.warning == null ? '' : ' (${s.warning})'}.');
      } else {
        parts.add('No battery reading arrived from $battery.');
      }
    } else {
      parts.add('This robot does not report its battery.');
    }
    final l = log;
    if (l != null) {
      final since = DateTime.now().subtract(const Duration(minutes: 10));
      final recent = [for (final e in l.entries) if (e.level.isProblem && e.time.isAfter(since)) e];
      final errors = recent.where((e) => e.level.index >= LogLevel.error.index).toList();
      final warnings = recent.where((e) => e.level == LogLevel.warn).toList();
      data['errors'] = [for (final e in errors.take(3)) '${e.node}: ${e.text}'];
      data['warnings'] = [for (final e in warnings.take(3)) '${e.node}: ${e.text}'];
      if (recent.isEmpty) {
        parts.add(l.heard ? 'No warnings or errors in the last 10 minutes.' : 'No log messages from the robot yet.');
      } else {
        parts.add('${errors.length} error${errors.length == 1 ? '' : 's'} and ${warnings.length} '
            'warning${warnings.length == 1 ? '' : 's'} in the last 10 minutes'
            '${errors.isNotEmpty ? '; latest error from ${errors.first.node}: "${_short(errors.first.text)}"' : ''}'
            '${errors.isEmpty && warnings.isNotEmpty ? '; latest warning from ${warnings.first.node}: "${_short(warnings.first.text)}"' : ''}.');
      }
    }
    if (_mapping?.mapping == true) parts.add('It is making a map (${_mapping!.mapper}).');
    return SkillResult(true, parts.join(' '), data);
  }

  static String _short(String t) => t.length <= 90 ? t : '${t.substring(0, 87)}…';

  // ---- where the robot is ----------------------------------------------------------------------

  /// Transforms seen on /tf and /tf_static within [listen].
  Future<TfTree> _tf({Duration listen = const Duration(milliseconds: 1500)}) async {
    final tf = TfTree();
    void take(Map<String, dynamic> m) {
      for (final t in (m['transforms'] as List? ?? const [])) {
        try { tf.add(t as Map); } catch (_) {}
      }
    }
    final subs = [
      ros.subscribe('$namespace/tf').listen(take, onError: (_) {}),
      ros.subscribe('$namespace/tf_static').listen(take, onError: (_) {}),
    ];
    await Future<void>.delayed(listen);
    for (final s in subs) {
      await s.cancel();
    }
    return tf;
  }

  static const _bases = ['base_footprint', 'base_link'];

  Future<Pose2D?> robotOnMap({String mapFrame = 'map'}) async {
    final tf = await _tf();
    for (final b in _bases) {
      final p = tf.lookup(mapFrame, b);
      if (p != null) return p;
    }
    return null;
  }

  Future<SkillResult> savePlace(String name) async {
    final book = places;
    if (book == null) return const SkillResult.failed('Places cannot be saved here.');
    final pose = await robotOnMap();
    if (pose == null) {
      return const SkillResult.failed('Could not tell where the robot is on the map (no map → robot transform). '
          'Make sure localization is running.');
    }
    if (!book.loaded) await book.load();
    // Another name for (almost) the same spot is usually a mistake or a duplicate: say so.
    final near = [
      for (final p in book.places)
        if (PlaceBook.normalize(p.name) != PlaceBook.normalize(name) &&
            math.sqrt(math.pow(p.x - pose.x, 2) + math.pow(p.y - pose.y, 2)) < 0.3) p.name,
    ];
    await book.save(Place(name, pose.x, pose.y, yaw: pose.yaw));
    return SkillResult(true, 'Saved this spot as "$name" (${pose.x.toStringAsFixed(2)}, ${pose.y.toStringAsFixed(2)}).'
        '${near.isEmpty ? '' : ' Note: ${near.map((n) => '"$n"').join(', ')} is saved at almost the same spot.'}',
        {'x': pose.x, 'y': pose.y, if (near.isNotEmpty) 'same_spot': near});
  }

  /// Matches the current laser scan against the whole map and, when one spot clearly fits, tells the
  /// robot's localization (AMCL) it is there. The robot does not move.
  Future<SkillResult> findPosition() async {
    final mapTopic = _map, scanTopic = _scan;
    if (mapTopic == null || scanTopic == null) {
      return const SkillResult.failed('Finding the position needs a map and a laser scanner.');
    }
    final mapMsg = await readOnce(ros, mapTopic, timeout: const Duration(seconds: 6));
    final scanMsg = await readOnce(ros, scanTopic);
    if (mapMsg == null) return SkillResult.failed('No map arrived from $mapTopic.');
    if (scanMsg == null) return SkillResult.failed('No laser scan arrived from $scanTopic.');
    final tf = await _tf();
    final info = mapMsg['info'] as Map, o = info['origin'] as Map;
    final width = (info['width'] as num).toInt(), height = (info['height'] as num).toInt();
    final resolution = (info['resolution'] as num).toDouble();
    final origin = Pose2D((o['position']['x'] as num).toDouble(), (o['position']['y'] as num).toDouble(),
        yawOf(o['orientation'] as Map));
    final cells = [for (final v in mapMsg['data'] as List) (v as num).toInt()];
    final mapFrame = TfTree.clean('${mapMsg['header']?['frame_id'] ?? 'map'}');
    // Laser points in the robot's base frame.
    final laser = TfTree.clean('${scanMsg['header']['frame_id']}');
    String? base;
    Pose2D? sensor;
    for (final b in _bases) {
      sensor = TfTree.clean(laser) == b ? Pose2D.identity : tf.lookup(b, laser);
      if (sensor != null) { base = b; break; }
    }
    if (sensor == null || base == null) {
      return SkillResult.failed('Could not place the laser ($laser) on the robot: no transform to base_link.');
    }
    final min = (scanMsg['angle_min'] as num).toDouble(), inc = (scanMsg['angle_increment'] as num).toDouble();
    final rMin = (scanMsg['range_min'] as num).toDouble(), rMax = (scanMsg['range_max'] as num).toDouble();
    final points = <math.Point<double>>[];
    final ranges = scanMsg['ranges'] as List;
    for (var i = 0; i < ranges.length; i++) {
      final r = ranges[i];
      if (r is! num || !r.isFinite || r < rMin || r > rMax) continue;
      final a = min + i * inc;
      points.add(sensor.apply(r * math.cos(a), r * math.sin(a)));
    }
    final prior = tf.lookup(mapFrame, base);
    final guess = await compute(findPose, PoseSearch(cells: cells, width: width, height: height,
        resolution: resolution, origin: origin, scan: points, prior: prior));
    if (guess == null) return const SkillResult.failed('The map or the scan is too small to match.');
    final pct = (guess.match * 100).round();
    if (!guess.good) {
      return SkillResult.failed('No spot on the map fits the laser well (best $pct%). The room may have changed; '
          'set the position by hand on the map.', {'match': guess.match});
    }
    if (guess.lookalikes > 0 && prior == null) {
      return SkillResult.failed('${guess.lookalikes + 1} spots look alike and the robot has no previous estimate to '
          'choose between them. Set the position by hand on the map.');
    }
    final topic = '$namespace$initialPoseTopic';
    final pub = ros.advertise(topic, initialPoseType(_version));
    try {
      final p = guess.pose;
      pub.publish(initialPoseMessage(_version, mapFrame, p.x, p.y, p.yaw));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } finally {
      pub.close();
    }
    final p = guess.pose;
    final moved = prior == null ? null : p.distanceTo(prior);
    return SkillResult(true, 'Position set to (${p.x.toStringAsFixed(2)}, ${p.y.toStringAsFixed(2)}), facing '
        '${((p.yaw * 180 / math.pi) % 360).round()}°; $pct% of the laser lines up with the map'
        '${moved == null ? '' : moved < 0.2 ? ' (it was already about right)' : ' (it was ${moved.toStringAsFixed(1)} m off)'}'
        '${guess.lookalikes > 0 ? '. Other spots look alike; this is the one nearest its previous estimate' : ''}.',
        {'x': p.x, 'y': p.y, 'match': guess.match});
  }

  // ---- save_map ------------------------------------------------------------------------------

  Future<SkillResult> saveMap(String? requested) async {
    final setup = _mapping, mapTopic = _map;
    if (setup == null || mapTopic == null) return const SkillResult.failed('The robot is not making a map.');
    final name = mapFileName(requested == null || requested.trim().isEmpty ? defaultMapName(DateTime.now()) : requested);
    final done = <String>[], problems = <String>[];
    if (setup.canSaveOnRobot) {
      try {
        await saveMapOnRobot(ros, setup, name, mapTopic: mapTopic.replaceFirst(RegExp('^/'), ''));
        done.add('on the robot');
      } catch (e) {
        problems.add(e is StateError ? e.message : '$e');
      }
    }
    final msg = await readOnce(ros, mapTopic, timeout: const Duration(seconds: 6));
    if (msg != null) {
      try {
        final info = msg['info'] as Map, o = info['origin'] as Map;
        final folder = await (mapFolder?.call() ??
            getApplicationDocumentsDirectory().then((d) => Directory('${d.path}/maps')));
        await saveMapOnPhone(folder, name, [for (final v in msg['data'] as List) (v as num).toInt()],
            (info['width'] as num).toInt(), (info['height'] as num).toInt(), (info['resolution'] as num).toDouble(),
            Pose2D((o['position']['x'] as num).toDouble(), (o['position']['y'] as num).toDouble(),
                yawOf(o['orientation'] as Map)));
        done.add('on this phone');
      } catch (e) {
        problems.add('Phone copy failed: $e');
      }
    }
    if (done.isEmpty) return SkillResult.failed('The map was not saved. ${problems.join(' ')}');
    return SkillResult(true, 'Saved the map as "$name" ${done.join(' and ')}.${problems.isEmpty ? '' : ' ${problems.join(' ')}'}',
        {'name': name});
  }
}
