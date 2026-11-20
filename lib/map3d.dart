import 'app_language.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4, Vector3, Vector4;

import 'map_geometry.dart';

/// A 3D look at the 2D map: the occupancy grid as the floor, its walls raised, and the robot, its laser
/// and its planned path on top. Drag to orbit, pinch to zoom; no 3D engine, just perspective
/// projection on a canvas (the floor picture is drawn through a 4x4 transform).
///
/// Walls and floor are redrawn only when the camera moves; the robot, laser and path, which change
/// many times a second, are a separate layer.

/// Orbit camera around [target] (map metres): [azimuth] around the vertical, [elevation] above the
/// floor (radians), [distance] in metres.
class OrbitCamera {
  const OrbitCamera({required this.target, this.azimuth = -math.pi / 2, this.elevation = 0.75, this.distance = 8});
  final Vector3 target;
  final double azimuth, elevation, distance;

  static const minElevation = 0.2, maxElevation = 1.5;

  OrbitCamera copyWith({Vector3? target, double? azimuth, double? elevation, double? distance}) => OrbitCamera(
      target: target ?? this.target, azimuth: azimuth ?? this.azimuth,
      elevation: (elevation ?? this.elevation).clamp(minElevation, maxElevation),
      distance: (distance ?? this.distance).clamp(1.0, 200.0));

  Vector3 get eye => target + Vector3(math.cos(elevation) * math.cos(azimuth),
      math.cos(elevation) * math.sin(azimuth), math.sin(elevation)) * distance;

  /// World (metres, z up) → screen pixels, as a 4x4 matrix (projection, then the viewport).
  Matrix4 matrix(Size size) {
    final view = _lookAt(eye, target, Vector3(0, 0, 1));
    final aspect = size.width / math.max(1, size.height);
    final proj = _perspective(50 * math.pi / 180, aspect, 0.1, 1000);
    final viewport = Matrix4.identity()
      ..setEntry(0, 0, size.width / 2)
      ..setEntry(0, 3, size.width / 2)
      ..setEntry(1, 1, -size.height / 2)
      ..setEntry(1, 3, size.height / 2);
    return viewport * proj * view;
  }

  static Matrix4 _lookAt(Vector3 eye, Vector3 target, Vector3 up) {
    final f = (target - eye)..normalize();
    final s = f.cross(up)..normalize();
    final u = s.cross(f);
    return Matrix4(
      s.x, u.x, -f.x, 0,
      s.y, u.y, -f.y, 0,
      s.z, u.z, -f.z, 0,
      -s.dot(eye), -u.dot(eye), f.dot(eye), 1,
    );
  }

  static Matrix4 _perspective(double fovY, double aspect, double near, double far) {
    final f = 1 / math.tan(fovY / 2);
    return Matrix4(
      f / aspect, 0, 0, 0,
      0, f, 0, 0,
      0, 0, (far + near) / (near - far), -1,
      0, 0, 2 * far * near / (near - far), 0,
    );
  }
}

/// Projects a world point; null when it is behind the camera.
Offset? project(Matrix4 m, double x, double y, double z) {
  final v = m.transform(Vector4(x, y, z, 1));
  if (v.w <= 0.05) return null;
  return Offset(v.x / v.w, v.y / v.w);
}

/// Intersects the camera ray with the map floor (z=0). A tap above the horizon has no floor point.
Offset? groundPoint(OrbitCamera camera, Size size, Offset screen) {
  if (size.isEmpty || !screen.dx.isFinite || !screen.dy.isFinite ||
      screen.dx < 0 || screen.dy < 0 || screen.dx > size.width || screen.dy > size.height) {
    return null;
  }
  final inverse = Matrix4.copy(camera.matrix(size));
  if (inverse.invert().abs() < 1e-12) return null;
  final a = inverse.transform(Vector4(screen.dx, screen.dy, -1, 1));
  final b = inverse.transform(Vector4(screen.dx, screen.dy, 1, 1));
  if (a.w.abs() < 1e-12 || b.w.abs() < 1e-12) return null;
  final near = Vector3(a.x / a.w, a.y / a.w, a.z / a.w);
  final far = Vector3(b.x / b.w, b.y / b.w, b.z / b.w);
  final ray = far - near;
  if (ray.z.abs() < 1e-9) return null;
  final t = -near.z / ray.z;
  if (t < 0) return null;
  final hit = near + ray * t;
  return hit.x.isFinite && hit.y.isFinite ? Offset(hit.x, hit.y) : null;
}

/// Wall cells merged into boxes (runs along each row), in metres in the map frame.
class WallBox {
  const WallBox(this.corners);
  /// The four floor corners, counter-clockwise.
  final List<Vector3> corners;
}

/// At most this many wall blocks along a side, and about this many boxes in all: a big or noisy site map
/// is drawn in coarser blocks in 3D (the cost of a frame follows the number of boxes), so the view stays
/// smooth on a phone. A small, clean map keeps every cell.
const maxWallBlocks = 512, maxWallBoxes = 3000;

/// Wall cells merged into boxes, in metres in the map frame: runs along each row, and the same run on
/// the rows above folded into one rectangle. A grid wider than [maxSide] is first coarsened (a block is a
/// wall when any of its cells is).
List<WallBox> wallBoxes(List<int> cells, int width, int height, double resolution, Pose2D origin,
    {int maxSide = maxWallBlocks, int maxBoxes = maxWallBoxes}) {
  if (width <= 0 || height <= 0 || cells.length < width * height) return const [];
  var k = math.max(1, (math.max(width, height) / maxSide).ceil());
  while (true) {
    final boxes = _wallBoxesAt(k, cells, width, height, resolution, origin);
    if (boxes.length <= maxBoxes || k >= math.max(width, height)) return boxes;
    k = (k * 1.5).ceil();
  }
}

List<WallBox> _wallBoxesAt(int k, List<int> cells, int width, int height, double resolution, Pose2D origin) {
  final out = <WallBox>[];
  final bw = (width / k).ceil(), bh = (height / k).ceil();
  final wall = List<bool>.filled(bw * bh, false);
  for (var row = 0; row < height; row++) {
    final br = row ~/ k * bw;
    for (var col = 0; col < width; col++) {
      if (cells[row * width + col] >= 65) wall[br + col ~/ k] = true;
    }
  }
  final c = math.cos(origin.yaw), s = math.sin(origin.yaw);
  Vector3 at(int bc, int brow) {
    final lx = math.min(bc * k, width) * resolution, ly = math.min(brow * k, height) * resolution;
    return Vector3(origin.x + lx * c - ly * s, origin.y + lx * s + ly * c, 0);
  }
  void close(int start, int end, int fromRow, int toRow) => out.add(WallBox([at(start, fromRow), at(end, fromRow),
    at(end, toRow), at(start, toRow)]));
  // Open rectangles by their run (start, end) → first row.
  var open = <(int, int), int>{};
  for (var row = 0; row < bh; row++) {
    final next = <(int, int), int>{};
    var col = 0;
    while (col < bw) {
      if (!wall[row * bw + col]) { col++; continue; }
      final start = col;
      while (col < bw && wall[row * bw + col]) { col++; }
      next[(start, col)] = open.remove((start, col)) ?? row;
    }
    open.forEach((run, from) => close(run.$1, run.$2, from, row));
    open = next;
  }
  open.forEach((run, from) => close(run.$1, run.$2, from, bh));
  return out;
}

class Map3DView extends StatefulWidget {
  const Map3DView({super.key, required this.image, required this.cells, required this.width, required this.height,
    required this.resolution, required this.origin, this.robot, this.scan = const [], this.path = const [],
    this.goal, this.wallHeight = 0.5, this.wallColor = const Color(0xFF34465A), this.background = const Color(0xFFE6ECF2),
    this.overview = false, this.movable = false, this.onMoved, this.onGroundTap, this.places = const []});
  final ui.Image? image;
  final List<int> cells;
  final int width, height;
  final double resolution;
  final Pose2D origin;
  final Pose2D? robot, goal;
  final List<math.Point<double>> scan, path;
  /// Saved places, as named pins (the same ones the 2D map shows).
  final List<(String, Pose2D)> places;
  final double wallHeight;
  final Color wallColor, background;
  /// A quiet, read-only follow camera for the home dashboard; its parent handles opening the map.
  final bool overview;
  /// An overview the person may turn and zoom; it stops following until [Map3DViewState.followAgain].
  final bool movable;
  final VoidCallback? onMoved;
  final ValueChanged<Offset>? onGroundTap;

  @override
  State<Map3DView> createState() => Map3DViewState();
}

class Map3DViewState extends State<Map3DView> {
  late OrbitCamera camera;
  List<WallBox> walls = const [];
  List<int>? _wallsFrom;
  OrbitCamera? _gestureStart;
  bool follow = false;
  /// The "drag to turn" hint goes once the person has moved the view.
  bool moved = false;

  @override
  void initState() {
    super.initState();
    camera = _fit();
    _walls();
  }

  @override
  void didUpdateWidget(Map3DView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.cells, widget.cells) || oldWidget.width != widget.width || oldWidget.height != widget.height ||
        oldWidget.resolution != widget.resolution || oldWidget.origin != widget.origin) {
      _wallsFrom = null;
      _walls();
    }
    final r = widget.robot;
    if (widget.overview && r != null && !_free) {
      camera = OrbitCamera(target: Vector3(r.x, r.y, 0), azimuth: r.yaw + math.pi, elevation: 0.9, distance: 7);
    } else if (follow && r != null) {
      camera = camera.copyWith(target: Vector3(r.x, r.y, 0));
    }
  }

  void _walls() {
    if (identical(_wallsFrom, widget.cells)) return;
    _wallsFrom = widget.cells;
    walls = wallBoxes(widget.cells, widget.width, widget.height, widget.resolution, widget.origin);
  }

  /// Looks at the middle of the map from far enough to see all of it.
  OrbitCamera _fit() {
    final robot = widget.robot;
    if (widget.overview && robot != null) {
      return OrbitCamera(target: Vector3(robot.x, robot.y, 0), azimuth: robot.yaw + math.pi, elevation: 0.9, distance: 7);
    }
    // Frame the part of the map that is known: a SLAM grid is mostly unknown space around the rooms.
    var minC = widget.width, maxC = -1, minR = widget.height, maxR = -1;
    for (var r = 0; r < widget.height; r++) {
      for (var c = 0; c < widget.width; c++) {
        if (widget.cells[r * widget.width + c] < 0) continue;
        if (c < minC) minC = c;
        if (c > maxC) maxC = c;
        if (r < minR) minR = r;
        if (r > maxR) maxR = r;
      }
    }
    if (maxC < 0) { minC = 0; maxC = widget.width - 1; minR = 0; maxR = widget.height - 1; }
    final res = widget.resolution;
    final w = (maxC - minC + 1) * res, h = (maxR - minR + 1) * res;
    final mid = widget.origin.apply((minC + maxC + 1) / 2 * res, (minR + maxR + 1) / 2 * res);
    // The view is 50° tall; a portrait phone sees less across, so step back to fit the width too.
    final aspect = _size == null || _size!.height <= 0 ? 1.0 : _size!.width / _size!.height;
    return OrbitCamera(target: Vector3(mid.x, mid.y, 0), distance: math.max(3, math.max(w, h) * 1.1 / math.min(1, aspect)));
  }

  /// The view's size at the last layout; the whole-map view depends on its shape.
  Size? _size;
  bool _fitted = false;

  void reset() => setState(() { camera = _fit(); follow = false; });

  /// The overview was moved by the person (it holds still until [followAgain]).
  bool _free = false;

  void followAgain() => setState(() {
    _free = false;
    camera = _fit();
  });

  bool get _gestures => !widget.overview || widget.movable;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
    // Until the person moves the view, the whole-map view follows the screen's shape (rotation, split).
    if (box.biggest.isFinite && box.biggest != _size) {
      _size = box.biggest;
      if (!moved && !follow && (!widget.overview || !_free) && (!_fitted || !widget.overview)) {
        camera = _fit();
        _fitted = true;
      }
    }
    return _view(box);
  });

  Widget _view(BoxConstraints box) => Stack(children: [
    Positioned.fill(child: GestureDetector(
      onTapUp: widget.onGroundTap == null ? null : (d) {
        final hit = groundPoint(camera, box.biggest, d.localPosition);
        if (hit != null) widget.onGroundTap!(hit);
      },
      onScaleStart: !_gestures ? null : (_) {
        _gestureStart = camera;
        moved = true;
        if (widget.overview && !_free) {
          _free = true;
          widget.onMoved?.call();
        }
      },
      onScaleUpdate: !_gestures ? null : (d) {
        final start = _gestureStart;
        if (start == null) return;
        setState(() {
          if (d.pointerCount > 1) {
            camera = camera.copyWith(distance: start.distance / d.scale);
          } else {
            camera = camera.copyWith(azimuth: camera.azimuth - d.focalPointDelta.dx * 0.008,
                elevation: camera.elevation + d.focalPointDelta.dy * 0.006);
          }
        });
      },
      child: Container(color: widget.background, child: Stack(children: [
        // Floor and walls: only when the camera or the map changes.
        Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _WorldPainter(this)))),
        Positioned.fill(child: CustomPaint(painter: _LivePainter(this))),
      ])),
    )),
    // Up the right side, clear of the cards at the top and bottom of the map screen.
    if (!widget.overview) Positioned(right: 12, top: box.maxHeight * 0.32, child: SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      FloatingActionButton.small(heroTag: 'map3d-follow', tooltip: follow ? 'Stop following the robot' : 'Follow the robot',
        onPressed: widget.robot == null ? null : () => setState(() {
          follow = !follow;
          final r = widget.robot;
          if (follow && r != null) camera = camera.copyWith(target: Vector3(r.x, r.y, 0), distance: 4);
        }),
        child: Icon(follow ? Icons.gps_fixed : Icons.gps_not_fixed)),
      const SizedBox(height: 8),
      FloatingActionButton.small(heroTag: 'map3d-reset', tooltip: context.strings.wholeMap, onPressed: reset,
        child: const Icon(Icons.zoom_out_map)),
    ]))),
    if (!widget.overview && !moved) Positioned(left: 0, right: 0, top: box.maxHeight * 0.24,
      child: IgnorePointer(child: Center(child: Container(
        key: const Key('map3d-hint'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.5), borderRadius: BorderRadius.circular(12)),
        child: Text(widget.onGroundTap == null ? 'Drag to turn · pinch to zoom' : 'Tap the floor to select · drag to turn',
          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 13)))))),
  ]);
}

class _WorldPainter extends CustomPainter {
  _WorldPainter(this.s) : camera = s.camera, image = s.widget.image, walls = s.walls;
  final Map3DViewState s;
  final OrbitCamera camera;
  final ui.Image? image;
  final List<WallBox> walls;

  @override
  void paint(Canvas canvas, Size size) {
    final w = s.widget;
    final m = camera.matrix(size);
    // Floor: the map picture placed in the world (pixel u, v → metres), seen through the camera.
    final img = image;
    if (img != null) {
      final res = w.resolution, o = w.origin;
      final c = math.cos(o.yaw), sn = math.sin(o.yaw);
      // u right, v down in the picture; row 0 of the picture is the far (top) edge of the map.
      final imageToWorld = Matrix4(
        res * c, res * sn, 0, 0,
        res * sn, -res * c, 0, 0,
        0, 0, 1, 0,
        o.x - w.height * res * sn, o.y + w.height * res * c, 0, 1,
      );
      canvas.save();
      canvas.transform((m * imageToWorld).storage);
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromLTWH(0, 0, w.width.toDouble(), w.height.toDouble()), Paint()..filterQuality = FilterQuality.medium);
      canvas.restore();
    }
    // Walls: faces facing the camera, far to near, drawn as one batch of triangles. A big map has thousands
    // of them, so this loop works on plain numbers: no objects per corner or face.
    final faces = _faces(m.storage, camera.eye, size, w.wallHeight);
    if (faces.count == 0) return;
    final order = List<int>.generate(faces.count, (i) => i)
      ..sort((a, b) => faces.depth[b].compareTo(faces.depth[a]));
    final positions = Float32List(faces.count * 12);
    final colors = Int32List(faces.count * 6);
    final top = Color.lerp(w.wallColor, Colors.white, 0.25)!.toARGB32();
    final shades = [for (var k = 0; k <= 30; k++) Color.lerp(Colors.black, w.wallColor, 0.55 + 0.01 * k)!.toARGB32()];
    var i = 0, j = 0;
    for (final f in order) {
      final light = faces.light[f];
      final colour = light >= 1 ? top : shades[((light - 0.55) * 100).round().clamp(0, 30)];
      final o = f * 8;
      for (final k in const [0, 1, 2, 0, 2, 3]) {
        positions[i++] = faces.xy[o + k * 2];
        positions[i++] = faces.xy[o + k * 2 + 1];
        colors[j++] = colour;
      }
    }
    canvas.drawVertices(ui.Vertices.raw(ui.VertexMode.triangles, positions, colors: colors), BlendMode.dst,
        Paint()..isAntiAlias = true);
  }

  /// The visible faces: screen corners (4 x/y each), distance to the eye and shade (1 = top).
  ({int count, Float32List xy, Float64List depth, Float64List light}) _faces(Float64List m, Vector3 eye, Size size,
      double height) {
    final n = walls.length;
    var xy = Float32List(n * 3 * 8);
    var depth = Float64List(n * 3), light = Float64List(n * 3);
    var count = 0;
    final px = Float64List(8), py = Float64List(8);
    final cx = Float64List(4), cy = Float64List(4);
    final ex = eye.x, ey = eye.y, ez = eye.z;
    final margin = size.shortestSide * 0.1;
    final left = -margin, right = size.width + margin, topEdge = -margin, bottom = size.height + margin;
    void add(int a, int b, int c, int d, double dist, double shade) {
      if (count * 8 + 8 > xy.length) {
        xy = Float32List(xy.length * 2)..setAll(0, xy);
        depth = Float64List(depth.length * 2)..setAll(0, depth);
        light = Float64List(light.length * 2)..setAll(0, light);
      }
      final o = count * 8;
      xy[o] = px[a]; xy[o + 1] = py[a]; xy[o + 2] = px[b]; xy[o + 3] = py[b];
      xy[o + 4] = px[c]; xy[o + 5] = py[c]; xy[o + 6] = px[d]; xy[o + 7] = py[d];
      depth[count] = dist;
      light[count] = shade;
      count++;
    }
    for (final box in walls) {
      final c = box.corners;
      // Project the 4 floor and 4 top corners; a box partly behind the camera is left out.
      var behind = false;
      var l = double.infinity, r = -double.infinity, t = double.infinity, b = -double.infinity;
      for (var k = 0; k < 8; k++) {
        final p = c[k & 3];
        final z = k < 4 ? 0.0 : height;
        final w = m[3] * p.x + m[7] * p.y + m[11] * z + m[15];
        if (w <= 0.05) { behind = true; break; }
        final x = (m[0] * p.x + m[4] * p.y + m[8] * z + m[12]) / w;
        final y = (m[1] * p.x + m[5] * p.y + m[9] * z + m[13]) / w;
        px[k] = x; py[k] = y;
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
      if (behind || r < left || l > right || b < topEdge || t > bottom) continue;
      for (var k = 0; k < 4; k++) { cx[k] = c[k].x; cy[k] = c[k].y; }
      final mx = (cx[0] + cx[2]) / 2, my = (cy[0] + cy[2]) / 2;
      double dist(double x, double y, double z) =>
          math.sqrt((x - ex) * (x - ex) + (y - ey) * (y - ey) + (z - ez) * (z - ez));
      add(4, 5, 6, 7, dist(mx, my, height), 1.0);
      for (var k = 0; k < 4; k++) {
        final k2 = (k + 1) & 3;
        final nx = cy[k2] - cy[k], ny = -(cx[k2] - cx[k]); // outward for counter-clockwise corners
        final sx = (cx[k] + cx[k2]) / 2, sy = (cy[k] + cy[k2]) / 2;
        if (nx * (ex - sx) + ny * (ey - sy) <= 0) continue; // faces away from the camera
        final len = math.sqrt(nx * nx + ny * ny);
        final shade = len == 0 ? 0.7 : 0.55 + 0.3 * ((nx * 0.4 - ny * 0.6) / len).abs();
        add(k, k2, k2 + 4, k + 4, dist(sx, sy, height / 2), shade);
      }
    }
    return (count: count, xy: xy, depth: depth, light: light);
  }

  @override
  bool shouldRepaint(_WorldPainter old) =>
      old.camera != camera || !identical(old.image, image) || !identical(old.walls, walls);
}

class _LivePainter extends CustomPainter {
  _LivePainter(this.s) : camera = s.camera, robot = s.widget.robot, scan = s.widget.scan, path = s.widget.path,
      goal = s.widget.goal;
  final Map3DViewState s;
  final OrbitCamera camera;
  final Pose2D? robot, goal;
  final List<math.Point<double>> scan, path;

  @override
  void paint(Canvas canvas, Size size) {
    final m = camera.matrix(size);
    // Planned path on the floor.
    if (path.length > 1) {
      final line = Path();
      var started = false;
      for (final p in path) {
        final o = project(m, p.x, p.y, 0.02);
        if (o == null) continue;
        started ? line.lineTo(o.dx, o.dy) : line.moveTo(o.dx, o.dy);
        started = true;
      }
      canvas.drawPath(line, Paint()..style = PaintingStyle.stroke..strokeWidth = 3..color = const Color(0xCC1E88E5)
        ..strokeJoin = StrokeJoin.round);
    }
    // Laser at about its height.
    final dots = <Offset>[
      for (final p in scan) ?project(m, p.x, p.y, 0.15),
    ];
    if (dots.isNotEmpty) {
      canvas.drawPoints(ui.PointMode.points, dots, Paint()..color = const Color(0xFFFF6D3F)..strokeWidth = 3
        ..strokeCap = StrokeCap.round);
    }
    for (final (name, pose) in s.widget.places) {
      _place(canvas, m, name, pose);
    }
    final g = goal;
    if (g != null) _pin(canvas, m, g, const Color(0xFF43A047));
    final r = robot;
    if (r != null) _robot(canvas, m, r);
  }

  /// A small box with an arrow on top showing its heading.
  void _robot(Canvas canvas, Matrix4 m, Pose2D r) {
    const half = 0.17, h = 0.18;
    final c = math.cos(r.yaw), s = math.sin(r.yaw);
    Vector3 at(double fx, double fy, double z) => Vector3(r.x + fx * c - fy * s, r.y + fx * s + fy * c, z);
    final base = [at(half, half, 0), at(-half, half, 0), at(-half, -half, 0), at(half, -half, 0)];
    final top = [for (final p in base) Vector3(p.x, p.y, h)];
    final eye = camera.eye;
    final body = Paint()..color = const Color(0xFF1565C0);
    final side = Paint()..color = const Color(0xFF0D47A1);
    final faces = <(double, List<Offset>, Paint)>[];
    for (var i = 0; i < 4; i++) {
      final a = base[i], b = base[(i + 1) % 4];
      final mid = (a + b) * 0.5;
      final normal = Vector3(b.y - a.y, -(b.x - a.x), 0);
      if (normal.dot(eye - mid) <= 0) continue; // faces away from the camera
      final pts = [for (final p in [a, b, top[(i + 1) % 4], top[i]]) project(m, p.x, p.y, p.z)];
      if (pts.contains(null)) continue;
      faces.add((eye.distanceTo(mid), pts.cast<Offset>(), side));
    }
    faces.sort((a, b) => b.$1.compareTo(a.$1));
    for (final (_, pts, p) in faces) {
      canvas.drawPath(Path()..addPolygon(pts, true), p);
    }
    final topPts = [for (final p in top) project(m, p.x, p.y, p.z)];
    if (!topPts.contains(null)) canvas.drawPath(Path()..addPolygon(topPts.cast<Offset>(), true), body);
    final arrow = [at(half * 0.9, 0, h + 0.005), at(-half * 0.5, half * 0.6, h + 0.005), at(-half * 0.2, 0, h + 0.005),
      at(-half * 0.5, -half * 0.6, h + 0.005)];
    final arrowPts = [for (final p in arrow) project(m, p.x, p.y, p.z)];
    if (!arrowPts.contains(null)) {
      canvas.drawPath(Path()..addPolygon(arrowPts.cast<Offset>(), true), Paint()..color = Colors.white);
    }
  }

  /// A saved place: a purple pin with its name above, like on the 2D map.
  void _place(Canvas canvas, Matrix4 m, String name, Pose2D p) {
    const color = Color(0xFF8E24AA);
    final foot = project(m, p.x, p.y, 0), head = project(m, p.x, p.y, 0.35);
    if (foot == null || head == null) return;
    canvas.drawCircle(foot, 4, Paint()..color = color.withValues(alpha: 0.5));
    canvas.drawLine(foot, head, Paint()..color = color..strokeWidth = 2.5);
    canvas.drawCircle(head, 6, Paint()..color = color);
    canvas.drawCircle(head, 6, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    final text = TextPainter(text: TextSpan(text: name, style: const TextStyle(color: Colors.white, fontSize: 12,
        fontWeight: FontWeight.w600)), textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')
      ..layout(maxWidth: 140);
    final box = Rect.fromCenter(center: head - Offset(0, 10 + text.height / 2), width: text.width + 12,
        height: text.height + 6);
    canvas.drawRRect(RRect.fromRectAndRadius(box, const Radius.circular(8)), Paint()..color = color.withValues(alpha: 0.9));
    text.paint(canvas, box.topLeft + const Offset(6, 3));
    text.dispose();
  }

  void _pin(Canvas canvas, Matrix4 m, Pose2D g, Color color) {
    // The way the robot will face on arrival: a flat arrow on the floor around the pin's foot.
    final c = math.cos(g.yaw), s = math.sin(g.yaw);
    Offset? floor(double fx, double fy) => project(m, g.x + fx * c - fy * s, g.y + fx * s + fy * c, 0.01);
    final ring = [for (var i = 0; i < 24; i++) floor(0.16 * math.cos(i * math.pi / 12), 0.16 * math.sin(i * math.pi / 12))];
    if (!ring.contains(null)) {
      final circle = Path()..addPolygon(ring.cast<Offset>(), true);
      canvas.drawPath(circle, Paint()..color = color.withValues(alpha: 0.25));
      canvas.drawPath(circle, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2);
    }
    final arrow = [floor(0.5, 0), floor(0.26, 0.13), floor(0.3, 0.045), floor(0.1, 0.045), floor(0.1, -0.045),
      floor(0.3, -0.045), floor(0.26, -0.13)];
    if (!arrow.contains(null)) {
      final path = Path()..addPolygon(arrow.cast<Offset>(), true);
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(path, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
    final foot = project(m, g.x, g.y, 0), head = project(m, g.x, g.y, 0.45);
    if (foot == null || head == null) return;
    canvas.drawLine(foot, head, Paint()..color = color..strokeWidth = 3);
    canvas.drawCircle(head, 7, Paint()..color = color);
    canvas.drawCircle(head, 7, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_LivePainter old) => true;
}
