import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'map_geometry.dart';

/// Nav2's costmaps, drawn over the map: what the planner and the controller believe is in the way.
/// The local costmap is a small window around the robot (in the odometry frame, moving with it); the global
/// one covers the map. Both come as `nav_msgs/OccupancyGrid`, cell values 0 (free) to 100 (lethal), where
/// 99 is "inscribed": the robot's footprint cannot be there at all.

enum CostmapKind { local, global }

/// The costmap topic of [kind] among [topics] (name → type), the robot's own namespace first. Null when the
/// robot publishes none. Only names Nav2 uses: another OccupancyGrid (the map itself) is not a costmap.
String? costmapTopicIn(Map<String, String> topics, CostmapKind kind, {String namespace = ''}) {
  final suffix = '${kind.name}_costmap/costmap';
  final found = [
    for (final e in topics.entries)
      if (e.value.replaceFirst('/msg/', '/') == 'nav_msgs/OccupancyGrid' && (e.key == '/$suffix' || e.key.endsWith('/$suffix'))) e.key,
  ]..sort();
  if (found.isEmpty) return null;
  final ns = namespace == '/' ? '' : namespace;
  if (ns.isNotEmpty) return found.where((t) => t == '$ns/$suffix').firstOrNull;
  return found.where((t) => t == '/$suffix').firstOrNull ?? (found.length == 1 ? found.first : null);
}

/// A costmap grid as received.
class Costmap {
  Costmap({required this.width, required this.height, required this.resolution, required this.origin,
    required this.frame, required this.cells});

  final int width, height;
  final double resolution;
  /// Where cell (0, 0) is, in [frame].
  final Pose2D origin;
  final String frame;
  final List<int> cells;

  /// More than this many cells is not drawn: a large global costmap arrives as JSON every second.
  static const maxCells = 1500000;

  /// The costmap in an OccupancyGrid message, or null when it is empty, inconsistent or too large to be worth it.
  static Costmap? fromMessage(Map msg) {
    final info = msg['info'];
    if (info is! Map) return null;
    final w = info['width'], h = info['height'], res = info['resolution'];
    final data = msg['data'];
    if (w is! int || h is! int || res is! num || data is! List) return null;
    if (w <= 0 || h <= 0 || res <= 0 || !res.isFinite || w * h > maxCells || data.length != w * h) return null;
    final o = info['origin'];
    final position = o is Map ? o['position'] : null;
    if (position is! Map) return null;
    final q = o['orientation'];
    return Costmap(
      width: w, height: h, resolution: res.toDouble(),
      origin: Pose2D((position['x'] as num).toDouble(), (position['y'] as num).toDouble(), q is Map ? yawOf(q) : 0),
      frame: '${(msg['header'] is Map ? (msg['header'] as Map)['frame_id'] : null) ?? ''}'.replaceFirst(RegExp('^/'), ''),
      cells: List<int>.from(data),
    );
  }

  /// RGBA pixels, ROS row 0 at the bottom of the picture. Free and unknown cells are see-through; the cost
  /// grows from a faint blue through yellow to red; the inscribed cells (99) are magenta, the lethal ones
  /// (100) red.
  Uint8List rgba() {
    final pixels = Uint8List(width * height * 4);
    for (var row = 0; row < height; row++) {
      var i = (height - 1 - row) * width * 4;
      var cell = row * width;
      for (var col = 0; col < width; col++, cell++, i += 4) {
        final (r, g, b, a) = costColor(cells[cell]);
        pixels[i] = r;
        pixels[i + 1] = g;
        pixels[i + 2] = b;
        pixels[i + 3] = a;
      }
    }
    return pixels;
  }
}

/// RGBA of one cost value (see [Costmap.rgba]).
(int, int, int, int) costColor(int cost) {
  if (cost <= 0 || cost > 100) return (0, 0, 0, 0);
  if (cost == 100) return (213, 0, 0, 170);
  if (cost == 99) return (194, 24, 91, 150);
  final t = cost / 98;
  // 1..98: blue (low) → yellow (high), getting stronger.
  final r = (30 + 225 * t).round(), g = (136 + 80 * t).round(), b = (229 - 200 * t).round();
  return (r, g, b, (45 + 100 * t).round());
}

/// A rasterised costmap and where it sits, for drawing.
class CostmapOverlay {
  CostmapOverlay({required this.image, required this.width, required this.height, required this.resolution,
    required this.origin, required this.toMap});

  final ui.Image image;
  final int width, height;
  final double resolution;
  /// Cell (0, 0) in the costmap's own frame.
  final Pose2D origin;
  /// The costmap's frame in the map frame ([Pose2D.identity] when they are the same).
  final Pose2D toMap;

  /// See [costmapCorners].
  (math.Point<double>, math.Point<double>, math.Point<double>) corners() =>
      costmapCorners(origin: origin, width: width, height: height, resolution: resolution, toMap: toMap);
}

/// World (map frame) points of a costmap picture's top-left, top-right and bottom-left corners: what places
/// the picture on the map, even when the costmap's frame is moved or turned against it.
(math.Point<double>, math.Point<double>, math.Point<double>) costmapCorners({
  required Pose2D origin, required int width, required int height, required double resolution, required Pose2D toMap}) {
  math.Point<double> at(double u, double v) {
    // u along the grid's x, v along its y (ROS: row 0 at the bottom, so the top edge is y = height).
    final c = math.cos(origin.yaw), s = math.sin(origin.yaw);
    return toMap.apply(origin.x + c * u - s * v, origin.y + s * u + c * v);
  }
  final w = width * resolution, h = height * resolution;
  return (at(0, h), at(w, h), at(0, 0));
}
