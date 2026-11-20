import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'map_geometry.dart' show Pose2D;

/// A named spot on the robot's map ("주방", "충전기"), for "go to the kitchen".
class Place {
  const Place(this.name, this.x, this.y, {this.yaw = 0, this.frame = 'map', this.floor});

  final String name;
  final double x, y;
  /// Heading to arrive with, radians in the map frame.
  final double yaw;
  final String frame;
  /// The floor's map ([PlaceBook.mapKey]) it was saved on, or null: a place for any map (saved before the
  /// floors were named, or on a map without a floor name).
  final String? floor;

  Pose2D get pose => Pose2D(x, y, yaw);

  Map<String, Object?> toJson() => {'name': name, 'x': x, 'y': y, 'yaw': yaw, 'frame': frame,
    if (floor != null) 'floor': floor};

  static Place? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'], x = json['x'], y = json['y'];
    if (name is! String || name.trim().isEmpty || x is! num || y is! num) return null;
    final yaw = json['yaw'], frame = json['frame'], floor = json['floor'];
    return Place(name.trim(), x.toDouble(), y.toDouble(),
        yaw: yaw is num ? yaw.toDouble() : 0, frame: frame is String && frame.isNotEmpty ? frame : 'map',
        floor: floor is String && floor.isNotEmpty ? floor : null);
  }
}

/// The places saved for one robot (per address, like the robot profile). The map page adds and removes
/// them; the AI assistant offers them as destinations.
/// Where the robot is, in a few words: the saved place it is at (within [near] metres), else coordinates.
String whereIs(Pose2D robot, List<Place> places, {double near = 1.0}) {
  Place? best;
  var bestD = near;
  for (final p in places) {
    final d = math.sqrt(math.pow(p.x - robot.x, 2) + math.pow(p.y - robot.y, 2));
    if (d <= bestD) {
      best = p;
      bestD = d;
    }
  }
  if (best != null) return 'At ${best.name}';
  return 'x ${robot.x.toStringAsFixed(1)} · y ${robot.y.toStringAsFixed(1)} m';
}

class PlaceBook extends ChangeNotifier {
  PlaceBook(this.robot);

  /// Which robot these places belong to, e.g. `192.168.0.10:9090`.
  final String robot;
  List<Place> _places = const [];
  bool _loaded = false;

  List<Place> get places => _places;
  bool get loaded => _loaded;

  String get _key => 'places:$robot';
  String get _floorsKey => 'floors:$robot';

  // ---- floors -------------------------------------------------------------------------------------
  // A building has a map per floor; the robot's map server loads the one it is on. A map is recognised by
  // its size, cell size and origin, which differ between floors. Naming the map that is shown makes it a
  // floor: places saved on it belong to it and are offered only while that map is loaded.

  /// Map key → floor.
  Map<String, Floor> _floors = const {};
  String? _mapKey;

  /// Recognises a map: one floor's map keeps these while the robot uses it.
  static String mapKey({required String frame, required int width, required int height, required double resolution,
      required double originX, required double originY}) =>
      '$frame:${width}x$height@${resolution.toStringAsFixed(3)}:${originX.toStringAsFixed(2)},${originY.toStringAsFixed(2)}';

  /// The map the robot uses now (from its map messages); null while unknown or being made.
  String? get currentMap => _mapKey;
  /// The name of the floor the robot is on, when this map has been named.
  String? get floor => _floors[_mapKey]?.name;
  /// The named floors, by map key.
  Map<String, Floor> get floors => _floors;

  void observeMap(String? key) {
    if (key == _mapKey) return;
    _mapKey = key;
    notifyListeners();
  }

  /// Names the map shown now as a floor (or renames it), with the map file on the robot that loads it
  /// ([mapFile], for switching floors from the app). An empty name forgets the floor (its places stay
  /// saved for it).
  Future<void> nameFloor(String name, {String? mapFile}) async {
    final key = _mapKey;
    if (key == null) return;
    final tidy = name.trim(), file = mapFile?.trim();
    _floors = {..._floors}..remove(key);
    if (tidy.isNotEmpty) _floors[key] = Floor(tidy, mapFile: file == null || file.isEmpty ? null : file);
    notifyListeners();
    try {
      await (await SharedPreferences.getInstance()).setString(_floorsKey,
          jsonEncode({for (final e in _floors.entries) e.key: e.value.toJson()}));
    } catch (_) { /* kept for this session */ }
  }

  /// The places that may be used on the map shown now: those of this floor and those for any map.
  List<Place> get usable => [for (final p in _places) if (p.floor == null || (floor != null && p.floor == _mapKey)) p];
  /// Saved for another floor: not shown and not offered as destinations here.
  int get elsewhere => _places.length - usable.length;
  String? floorName(String? key) => key == null ? null : _floors[key]?.name;

  /// Two names are the same place when they match ignoring case and surrounding spaces.
  static String normalize(String name) => name.trim().toLowerCase();

  Place? find(String name) {
    final n = normalize(name);
    return _places.where((p) => normalize(p.name) == n).firstOrNull;
  }

  Future<void> load() async {
    try {
      final floors = jsonDecode((await SharedPreferences.getInstance()).getString(_floorsKey) ?? '{}');
      _floors = {if (floors is Map) for (final e in floors.entries) '${e.key}': ?Floor.fromJson(e.value)};
    } catch (_) {
      _floors = const {};
    }
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key);
      final list = raw == null ? const [] : jsonDecode(raw);
      _places = [
        if (list is List)
          for (final item in list) ?Place.fromJson(item),
      ];
    } catch (_) {
      _places = const []; // unreadable storage: start empty rather than fail the screen
    }
    _loaded = true;
    notifyListeners();
  }

  /// Saves [place], replacing one with the same name. On a named floor it belongs to that floor.
  Future<void> save(Place place) async {
    final n = normalize(place.name);
    final tidy = Place(place.name.trim(), place.x, place.y, yaw: place.yaw, frame: place.frame,
        floor: place.floor ?? (floor != null ? _mapKey : null));
    _places = [for (final p in _places) if (normalize(p.name) != n) p, tidy];
    notifyListeners();
    await _store();
  }

  Future<void> remove(String name) async {
    final n = normalize(name);
    _places = [for (final p in _places) if (normalize(p.name) != n) p];
    notifyListeners();
    await _store();
  }

  Future<void> _store() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode([for (final p in _places) p.toJson()]));
    } catch (_) { /* kept for this session */ }
  }
}

/// A floor of the building: its name, and the map file on the robot that loads it.
class Floor {
  const Floor(this.name, {this.mapFile});
  final String name;
  /// A map YAML path on the robot (what its map server loads), e.g. `/home/ubuntu/maps/2f.yaml`.
  final String? mapFile;

  Object toJson() => mapFile == null ? name : {'name': name, 'map': mapFile};

  /// Also reads the plain name an earlier version stored.
  static Floor? fromJson(Object? json) {
    if (json is String && json.trim().isNotEmpty) return Floor(json.trim());
    if (json is Map && json['name'] is String && (json['name'] as String).trim().isNotEmpty) {
      final map = json['map'];
      return Floor((json['name'] as String).trim(), mapFile: map is String && map.isNotEmpty ? map : null);
    }
    return null;
  }
}
