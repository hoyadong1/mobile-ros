import 'dart:math' as math;
import 'dart:typed_data';

import 'map_geometry.dart';

/// Finding where the robot is by matching its laser scan against the map, on the phone: no motion,
/// about a second. The person sees the result as a preview (the laser drawn at the found spot) and
/// confirms it with Set pose, which is what the robot's own localisation (AMCL) then starts from.

/// Occupancy at or above this is a wall.
const _wall = 65;

/// A wall cell a laser can actually hit: next to free floor. The inside of a thick or filled-in wall is
/// not, so a scan placed inside one does not "fit".
bool _surface(List<int> cells, int width, int height, int col, int row) {
  if (cells[row * width + col] < _wall) return false;
  for (var r = row - 1; r <= row + 1; r++) {
    for (var c = col - 1; c <= col + 1; c++) {
      if (r < 0 || c < 0 || r >= height || c >= width) continue;
      final v = cells[r * width + c];
      if (v >= 0 && v < 25) return true;
    }
  }
  return false;
}

/// Share of laser points that land on (or next to) a wall cell of the map: how well a pose agrees with
/// what the robot sees. [scan] is in the map frame. Null when there is nothing to compare.
///
/// [cells] is the occupancy grid (row 0 at the map bottom), [origin] the pose of cell (0, 0).
double? scanMatch(List<math.Point<double>> scan, List<int> cells, int width, int height, double resolution,
    Pose2D origin, {int tolerance = 1}) {
  if (scan.length < 10 || cells.length != width * height || resolution <= 0) return null;
  final c = math.cos(-origin.yaw), s = math.sin(-origin.yaw);
  var inside = 0, hits = 0;
  for (final p in scan) {
    final dx = p.x - origin.x, dy = p.y - origin.y;
    final col = ((dx * c - dy * s) / resolution).floor(), row = ((dx * s + dy * c) / resolution).floor();
    if (col < 0 || row < 0 || col >= width || row >= height) continue;
    inside++;
    var hit = false;
    for (var r = row - tolerance; r <= row + tolerance && !hit; r++) {
      if (r < 0 || r >= height) continue;
      for (var k = col - tolerance; k <= col + tolerance; k++) {
        if (k >= 0 && k < width && _surface(cells, width, height, k, r)) { hit = true; break; }
      }
    }
    if (hit) hits++;
  }
  return inside < 10 ? null : hits / inside;
}

/// What [findPose] found.
class PoseGuess {
  const PoseGuess(this.pose, this.match, {this.lookalikes = 0});
  final Pose2D pose;
  /// [scanMatch] at [pose], 0..1.
  final double match;
  /// Other, clearly different spots that fit about as well (a symmetric room); the one nearest the
  /// robot's own estimate was chosen.
  final int lookalikes;
  bool get good => match >= goodMatch;
  static const goodMatch = 0.6;
}

/// Input for [findPose]; plain data so it can run in a background isolate.
class PoseSearch {
  const PoseSearch({required this.cells, required this.width, required this.height, required this.resolution,
    required this.origin, required this.scan, this.prior});
  final List<int> cells;
  final int width, height;
  final double resolution;
  final Pose2D origin;
  /// Laser points in the robot's base frame.
  final List<math.Point<double>> scan;
  /// Where the robot thinks it is, used only to choose between lookalike spots.
  final Pose2D? prior;
}

/// Searches every free spot and heading of the map for the pose at which [PoseSearch.scan] lines up
/// best with the walls: coarse grid first, then the best few are refined. Null when the map or scan is
/// too small to say anything.
PoseGuess? findPose(PoseSearch q) {
  final w = q.width, h = q.height, res = q.resolution;
  if (q.scan.length < 10 || q.cells.length != w * h || res <= 0) return null;
  final field = _Field(q.cells, w, h, res);
  // At most ~90 points: plenty to judge a fit, and keeps the search fast.
  final stride = math.max(1, (q.scan.length / 90).ceil());
  final pts = [for (var i = 0; i < q.scan.length; i += stride) q.scan[i]];
  final px = Float64List.fromList([for (final p in pts) p.x]), py = Float64List.fromList([for (final p in pts) p.y]);
  final oc = math.cos(q.origin.yaw), os = math.sin(q.origin.yaw);

  // Score of a pose given in grid coordinates (cells, radians relative to the grid).
  double score(double gx, double gy, double a) {
    final c = math.cos(a), s = math.sin(a);
    var sum = 0.0;
    for (var i = 0; i < px.length; i++) {
      sum += field.at(gx + (px[i] * c - py[i] * s) / res, gy + (px[i] * s + py[i] * c) / res);
    }
    return sum / px.length;
  }

  // The robot stands on known free floor, its body clear of walls (about 10 cm around its centre).
  final body = 0.1 / res;
  bool freeCell(double gx, double gy) {
    final c = gx.floor(), r = gy.floor();
    if (c < 0 || r < 0 || c >= w || r >= h) return false;
    final v = q.cells[r * w + c];
    return v >= 0 && v < 25;
  }
  bool free(double gx, double gy) => freeCell(gx, gy) && freeCell(gx + body, gy) && freeCell(gx - body, gy) &&
      freeCell(gx, gy + body) && freeCell(gx, gy - body);

  // Coarse: free cells every ~0.15 m, headings every 10°.
  final step = math.max(1, (0.15 / res).round());
  const headings = 36;
  final coarse = <(double, double, double, double)>[]; // gx, gy, a, score
  for (var row = 0; row < h; row += step) {
    for (var col = 0; col < w; col += step) {
      final gx = col + 0.5, gy = row + 0.5;
      if (!free(gx, gy)) continue; // only known free floor, with room for the robot
      for (var k = 0; k < headings; k++) {
        final a = k * 2 * math.pi / headings;
        coarse.add((gx, gy, a, score(gx, gy, a)));
      }
    }
  }
  if (coarse.isEmpty) return null;
  coarse.sort((a, b) => b.$4.compareTo(a.$4));

  // Refine the best distinct candidates by hill climbing.
  final refined = <(double, double, double, double)>[];
  var tried = 0;
  for (final c in coarse) {
    if (tried >= 12) break;
    if (refined.any((r) => _near(r, c, 0.4 / res))) continue;
    var (gx, gy, a, best) = c;
    for (final (dp, da) in [(step / 2, 0.09), (1.0, 0.035), (0.4, 0.012)]) {
      var improved = true;
      while (improved) {
        improved = false;
        for (final (dx, dy, dth) in [(dp, 0.0, 0.0), (-dp, 0.0, 0.0), (0.0, dp, 0.0), (0.0, -dp, 0.0),
            (0.0, 0.0, da), (0.0, 0.0, -da)]) {
          if (!free(gx + dx, gy + dy)) continue;
          final s = score(gx + dx, gy + dy, a + dth);
          if (s > best + 1e-9) { gx += dx; gy += dy; a += dth; best = s; improved = true; }
        }
      }
    }
    tried++;
    // Several starts often climb to the same spot: keep it once.
    final r = (gx, gy, a, best);
    if (!refined.any((o) => _near(o, r, 0.3 / res))) refined.add(r);
  }
  refined.sort((a, b) => b.$4.compareTo(a.$4));

  Pose2D toWorld((double, double, double, double) g) {
    final lx = g.$1 * res, ly = g.$2 * res;
    return Pose2D(q.origin.x + lx * oc - ly * os, q.origin.y + lx * os + ly * oc, normalizeAngle(g.$3 + q.origin.yaw));
  }

  // Spots that fit nearly as well as the best are lookalikes; pick the one nearest the robot's guess.
  final top = refined.first.$4;
  final alike = [for (final r in refined) if (r.$4 >= top * 0.95) r];
  var chosen = refined.first;
  final prior = q.prior;
  if (prior != null && alike.length > 1) {
    double cost((double, double, double, double) r) {
      final p = toWorld(r);
      return p.distanceTo(prior) + 0.5 * normalizeAngle(p.yaw - prior.yaw).abs();
    }
    chosen = alike.reduce((a, b) => cost(a) <= cost(b) ? a : b);
  }
  final pose = toWorld(chosen);
  final world = [for (final p in q.scan) pose.apply(p.x, p.y)];
  final match = scanMatch(world, q.cells, w, h, res, q.origin) ?? 0;
  return PoseGuess(pose, match, lookalikes: alike.length - 1);
}

bool _near((double, double, double, double) a, (double, double, double, double) b, double cells) =>
    math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2)) < cells &&
    normalizeAngle(a.$3 - b.$3).abs() < 0.5;

/// How close each cell is to a wall, as a 0..1 likelihood (1 on a wall, fading over ~0.1 m): a smooth
/// score, so poses near the right one score nearly as well and refinement can climb to it.
class _Field {
  _Field(List<int> cells, this.w, this.h, double res) : values = Float32List(w * h) {
    // Two-pass chamfer distance transform (in cells) from the walls.
    const big = 1e9, diag = 1.41421356;
    final d = Float64List(w * h);
    for (var i = 0; i < d.length; i++) {
      d[i] = _surface(cells, w, h, i % w, i ~/ w) ? 0 : big;
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        var v = d[i];
        if (x > 0) v = math.min(v, d[i - 1] + 1);
        if (y > 0) {
          v = math.min(v, d[i - w] + 1);
          if (x > 0) v = math.min(v, d[i - w - 1] + diag);
          if (x < w - 1) v = math.min(v, d[i - w + 1] + diag);
        }
        d[i] = v;
      }
    }
    for (var y = h - 1; y >= 0; y--) {
      for (var x = w - 1; x >= 0; x--) {
        final i = y * w + x;
        var v = d[i];
        if (x < w - 1) v = math.min(v, d[i + 1] + 1);
        if (y < h - 1) {
          v = math.min(v, d[i + w] + 1);
          if (x < w - 1) v = math.min(v, d[i + w + 1] + diag);
          if (x > 0) v = math.min(v, d[i + w - 1] + diag);
        }
        d[i] = v;
      }
    }
    final sigma = math.max(1.0, 0.1 / res); // cells
    for (var i = 0; i < d.length; i++) {
      values[i] = math.exp(-d[i] * d[i] / (2 * sigma * sigma));
    }
  }

  final int w, h;
  final Float32List values;

  double at(double gx, double gy) {
    final x = gx.floor(), y = gy.floor();
    if (x < 0 || y < 0 || x >= w || y >= h) return 0;
    return values[y * w + x];
  }
}
