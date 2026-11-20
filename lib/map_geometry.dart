import 'dart:math';

enum MapCellState { free, occupied, unknown, outside }

MapCellState mapCellAt(double x, double y, {required List<int> cells, required int width,
    required int height, required double resolution, required Pose2D origin}) {
  if (!x.isFinite || !y.isFinite || !resolution.isFinite || resolution <= 0 || width <= 0 || height <= 0 ||
      cells.length != width * height) {
    return MapCellState.outside;
  }
  final p = transformPoint(x - origin.x, y - origin.y, 0, 0, -origin.yaw);
  final col = (p.x / resolution).floor(), row = (p.y / resolution).floor();
  if (col < 0 || row < 0 || col >= width || row >= height) return MapCellState.outside;
  final value = cells[row * width + col];
  return value < 0 ? MapCellState.unknown : value >= 65 ? MapCellState.occupied : MapCellState.free;
}

Point<double> transformPoint(double x, double y,
    double translationX, double translationY, double yaw) =>
    Point(translationX + cos(yaw) * x - sin(yaw) * y,
        translationY + sin(yaw) * x + cos(yaw) * y);

Point<double> screenToWorld(double x, double y, double screenWidth,
    double screenHeight, int width, int height, double resolution,
    double originX, double originY, double originYaw) {
  return transformPoint(x / screenWidth * width * resolution,
      (1 - y / screenHeight) * height * resolution,
      originX, originY, originYaw);
}

Point<double> worldToScreen(double x, double y, double screenWidth,
    double screenHeight, int width, int height, double resolution,
    double originX, double originY, double originYaw) {
  final local = transformPoint(x - originX, y - originY, 0, 0, -originYaw);
  return Point(local.x / resolution / width * screenWidth,
      (1 - local.y / resolution / height) * screenHeight);
}

/// A planar pose (x, y in metres, yaw in radians).
class Pose2D {
  final double x, y, yaw;
  const Pose2D(this.x, this.y, this.yaw);
  static const identity = Pose2D(0, 0, 0);

  /// this ∘ other: [other] expressed in this pose's frame, returned in the parent frame.
  Pose2D compose(Pose2D other) {
    final p = transformPoint(other.x, other.y, x, y, yaw);
    return Pose2D(p.x, p.y, normalizeAngle(yaw + other.yaw));
  }

  Point<double> apply(double px, double py) => transformPoint(px, py, x, y, yaw);
  double distanceTo(Pose2D o) => sqrt(pow(o.x - x, 2) + pow(o.y - y, 2));
  @override
  String toString() => 'Pose2D(${x.toStringAsFixed(2)}, ${y.toStringAsFixed(2)}, ${(yaw * 180 / pi).toStringAsFixed(0)}°)';
}

double normalizeAngle(double a) => atan2(sin(a), cos(a));

/// Yaw (rotation about z) of a ROS quaternion map {x, y, z, w}.
double yawOf(Map q) {
  final x = (q['x'] as num).toDouble(), y = (q['y'] as num).toDouble();
  final z = (q['z'] as num).toDouble(), w = (q['w'] as num).toDouble();
  return atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z));
}

Map<String, double> quaternionFromYaw(double yaw) => {'x': 0.0, 'y': 0.0, 'z': sin(yaw / 2), 'w': cos(yaw / 2)};

/// The planar part of /tf and /tf_static: each child frame keeps its latest transform from its parent,
/// and any frame's pose in a root frame is found by walking up the tree.
class TfTree {
  final _parent = <String, (String, Pose2D)>{};

  static String clean(String frame) => frame.replaceFirst(RegExp(r'^/'), '');

  /// Adds a geometry_msgs/TransformStamped map. Returns true if it changed anything.
  bool add(Map transform) {
    final parent = clean(transform['header']['frame_id'] as String);
    final child = clean(transform['child_frame_id'] as String);
    final t = transform['transform'] as Map;
    final pose = Pose2D((t['translation']['x'] as num).toDouble(), (t['translation']['y'] as num).toDouble(),
        yawOf(t['rotation'] as Map));
    final old = _parent[child];
    if (old != null && old.$1 == parent && old.$2.x == pose.x && old.$2.y == pose.y && old.$2.yaw == pose.yaw) {
      return false;
    }
    _parent[child] = (parent, pose);
    return true;
  }

  bool has(String child) => _parent.containsKey(clean(child));

  /// Pose of [frame] in [root], or null if the chain does not reach [root].
  Pose2D? lookup(String root, String frame) {
    root = clean(root);
    var current = clean(frame);
    final chain = <Pose2D>[];
    for (var depth = 0; current != root; depth++) {
      final link = _parent[current];
      if (link == null || depth > 32) return null;
      chain.add(link.$2);
      current = link.$1;
    }
    return chain.reversed.fold<Pose2D>(Pose2D.identity, (acc, t) => acc.compose(t));
  }
}

/// The known part of an occupancy grid (cells that are not -1) with [margin] cells around it: the cells,
/// size, and where it starts in the full grid (column [left], row [bottom]; row 0 is the bottom).
({List<int> cells, int width, int height, int left, int bottom}) cropToKnown(List<int> cells, int width, int height,
    {int margin = 0}) {
  var minC = width, maxC = -1, minR = height, maxR = -1;
  for (var r = 0; r < height; r++) {
    for (var c = 0; c < width; c++) {
      if (cells[r * width + c] < 0) continue;
      if (c < minC) minC = c;
      if (c > maxC) maxC = c;
      if (r < minR) minR = r;
      if (r > maxR) maxR = r;
    }
  }
  if (maxC < 0) return (cells: cells, width: width, height: height, left: 0, bottom: 0);
  final l = max(0, minC - margin), rgt = min(width - 1, maxC + margin);
  final b = max(0, minR - margin), t = min(height - 1, maxR + margin);
  final w = rgt - l + 1, h = t - b + 1;
  return (cells: [for (var r = b; r <= t; r++) ...cells.sublist(r * width + l, r * width + l + w)],
      width: w, height: h, left: l, bottom: b);
}
