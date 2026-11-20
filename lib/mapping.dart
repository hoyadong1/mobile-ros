import 'dart:io';

import 'map_geometry.dart';
import 'ros_client.dart';
import 'ros_connection.dart';

/// Making a map: which mapping program the robot runs, and saving what it built.
///
/// The app cannot start programs on the robot, so mapping mode (slam_toolbox, Cartographer, …) is
/// started there; the app shows the map growing, drives the robot around, and saves the result: on the
/// robot through its map saver service, and a copy on the phone.

/// How the robot can save its map.
enum MapSaver {
  /// Nav2's map_saver_server: `nav2_msgs/srv/SaveMap` (writes .pgm + .yaml where it runs).
  nav2,
  /// slam_toolbox's own `slam_toolbox/srv/SaveMap`.
  slamToolbox,
}

class MappingSetup {
  const MappingSetup({this.mapper, this.saver, this.saveService});

  /// The mapping program found running (`slam_toolbox`, `cartographer`, `gmapping`, `hector_mapping`).
  final String? mapper;
  final MapSaver? saver;
  final String? saveService;

  bool get mapping => mapper != null;
  bool get canSaveOnRobot => saveService != null;
}

const _mappers = {
  'slam_toolbox': 'slam_toolbox',
  'cartographer_node': 'Cartographer',
  'slam_gmapping': 'GMapping',
  'gmapping': 'GMapping',
  'hector_mapping': 'Hector SLAM',
  'rtabmap': 'RTAB-Map',
};

/// The mapping program in [nodes] (`slam_toolbox`, `Cartographer`, ...), or null when none runs.
String? mapperIn(List<String> nodes) {
  for (final n in nodes) {
    final base = n.split('/').last;
    for (final e in _mappers.entries) {
      if (base == e.key || base.startsWith('${e.key}_')) return e.value;
    }
  }
  return null;
}

/// What the robot offers for making a map, from its node list and services (rosapi).
Future<MappingSetup> detectMapping(RosConnection connection, List<String> nodes, {String namespace = ''}) async {
  final mapper = mapperIn(nodes);
  List<String> services = const [];
  try {
    final r = await connection.call('/rosapi/services').timeout(const Duration(seconds: 5));
    services = [for (final s in (r['services'] as List? ?? const [])) '$s'];
  } catch (_) {}
  String? find(String suffix) {
    final mine = services.where((s) => s.endsWith(suffix)).toList();
    if (mine.isEmpty) return null;
    return mine.firstWhere((s) => namespace.isNotEmpty && s.startsWith('$namespace/'), orElse: () => mine.first);
  }
  final nav2 = find('/map_saver/save_map'), slam = find('/slam_toolbox/save_map');
  return MappingSetup(mapper: mapper,
      saver: nav2 != null ? MapSaver.nav2 : slam != null ? MapSaver.slamToolbox : null,
      saveService: nav2 ?? slam);
}

/// Saves the map on the robot under [name] (a file name, or a path on the robot). Throws with a
/// readable reason when the robot says no.
Future<void> saveMapOnRobot(RosClient ros, MappingSetup setup, String name, {String mapTopic = 'map'}) async {
  final service = setup.saveService;
  if (service == null) throw StateError('This robot has no map saver running.');
  switch (setup.saver!) {
    case MapSaver.nav2:
      final r = await ros.callService(service, {
        'map_topic': mapTopic, 'map_url': name, 'image_format': 'pgm', 'map_mode': 'trinary',
        'free_thresh': 0.25, 'occupied_thresh': 0.65,
      }).timeout(const Duration(seconds: 20));
      if (r['result'] != true) throw StateError('The robot\'s map saver could not save "$name".');
    case MapSaver.slamToolbox:
      final r = await ros.callService(service, {'name': {'data': name}}).timeout(const Duration(seconds: 20));
      final code = r['result'];
      if (code is num && code != 0) throw StateError('slam_toolbox could not save "$name" (code $code).');
  }
}

/// A map name that is safe as a file name: letters, digits, `-` and `_`.
String mapFileName(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r'[^A-Za-z0-9_\-]+'), '_').replaceAll(RegExp('_+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^_|_$'), '');
  return trimmed.isEmpty ? 'map' : trimmed;
}

String defaultMapName(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'map_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}';
}

/// Square metres of known free floor.
double mappedArea(List<int> cells, double resolution) {
  var free = 0;
  for (final v in cells) {
    if (v >= 0 && v < 25) free++;
  }
  return free * resolution * resolution;
}

/// The map as ROS map_server files: a binary PGM (trinary: free 254, wall 0, unknown 205; top row is
/// the far end of the map) and its YAML.
({List<int> pgm, String yaml}) mapFiles(String name, List<int> cells, int width, int height, double resolution,
    Pose2D origin) {
  final header = 'P5\n# Mobile ROS\n$width $height\n255\n'.codeUnits;
  final pixels = List<int>.filled(width * height, 205);
  for (var row = 0; row < height; row++) {
    final src = (height - 1 - row) * width; // ROS row 0 is the bottom of the image
    for (var x = 0; x < width; x++) {
      final v = cells[src + x];
      pixels[row * width + x] = v < 0 ? 205 : v >= 65 ? 0 : v <= 25 ? 254 : 205;
    }
  }
  final yaml = 'image: $name.pgm\nmode: trinary\nresolution: $resolution\n'
      'origin: [${origin.x}, ${origin.y}, ${origin.yaw}]\nnegate: 0\noccupied_thresh: 0.65\nfree_thresh: 0.25\n';
  return (pgm: [...header, ...pixels], yaml: yaml);
}

/// Writes [mapFiles] into [folder]; returns the YAML file's path.
Future<String> saveMapOnPhone(Directory folder, String name, List<int> cells, int width, int height,
    double resolution, Pose2D origin) async {
  await folder.create(recursive: true);
  final files = mapFiles(name, cells, width, height, resolution, origin);
  await File('${folder.path}/$name.pgm').writeAsBytes(files.pgm, flush: true);
  final yaml = File('${folder.path}/$name.yaml');
  await yaml.writeAsString(files.yaml, flush: true);
  return yaml.path;
}

/// What to run on the robot to start mapping, for the screen that explains it.
const mappingStartHelp = [
  ('ROS 2 with slam_toolbox', 'ros2 launch slam_toolbox online_async_launch.py'),
  ('ROS 2 Nav2 (mapping while navigating)', 'ros2 launch nav2_bringup bringup_launch.py slam:=True'),
  ('TurtleBot3', 'ros2 launch turtlebot3_cartographer cartographer.launch.py'),
  ('ROS 1 with GMapping', 'rosrun gmapping slam_gmapping'),
];

// ---- floors: loading another map ----------------------------------------------------------------

/// Nav2 map_server's `nav2_msgs/srv/LoadMap` in [services] (the robot's own namespace first), or null.
String? loadMapService(List<String> services, {String namespace = ''}) {
  final mine = services.where((s) => s.endsWith('/map_server/load_map')).toList();
  if (mine.isEmpty) return null;
  return mine.firstWhere((s) => namespace.isNotEmpty && s.startsWith('$namespace/'), orElse: () => mine.first);
}

/// The robot's services (rosapi), or none when it cannot tell.
Future<List<String>> robotServices(RosConnection connection) async {
  try {
    final r = await connection.call('/rosapi/services').timeout(const Duration(seconds: 5));
    return [for (final s in (r['services'] as List? ?? const [])) '$s'];
  } catch (_) {
    return const [];
  }
}

/// Asks the robot's map server to load [url] (a map YAML on the robot). The new map then arrives on the
/// map topic. Nothing moves; localization needs the robot's position on the new map afterwards.
/// Throws with a readable reason when the robot says no.
Future<void> loadMapOnRobot(RosClient ros, String service, String url) async {
  final r = await ros.callService(service, {'map_url': url}).timeout(const Duration(seconds: 30));
  final code = r['result'];
  if (code == 0 || code == null && r['map'] != null) return;
  throw StateError(switch (code) {
    1 => 'The robot has no map file "$url".',
    2 => 'The map image in "$url" could not be read.',
    3 => 'The map file "$url" is not a valid map description.',
    _ => 'The robot\'s map server could not load "$url".',
  });
}
