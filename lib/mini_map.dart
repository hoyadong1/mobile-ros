import 'app_language.dart';
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'map3d.dart';
import 'map_geometry.dart';
import 'map_page.dart' show MapPalette;
import 'places.dart';
import 'robot_capabilities.dart';
import 'ros_client.dart';
import 'ros_connection.dart';
import 'widgets/throttled_rebuild.dart';

/// Where the robot is, for the driving screen: a small map around the robot, turned so that the robot
/// always points up (the way the camera looks). Tap to make it bigger or smaller. Shown only when the
/// robot publishes a map; read-only, it never sends anything.
class MiniMap extends StatefulWidget {
  const MiniMap({super.key, required this.connection, this.capabilities, this.namespace = '', this.maxSide = 220,
    this.height, this.onTap, this.onSnapshot, this.allow3d = false, this.places});

  final RosConnection connection;
  final Future<RobotCapabilities> Function()? capabilities;
  final String namespace;

  /// A wide strip this tall (full width) instead of the square; a tap then calls [onTap].
  final double? height;
  final VoidCallback? onTap;
  final bool allow3d;
  static const homeViewKey = 'home_map_3d';
  /// Told which map (floor) the robot uses, so the floor's places are the ones offered.
  final PlaceBook? places;

  /// Every few seconds, when the robot moved or the map changed, a small picture of this view for the home
  /// screen widget (PNG bytes, [snapshotSize] square). Only the home screen's map passes it.
  final void Function(Uint8List png, Pose2D robot)? onSnapshot;
  static const snapshotSize = 320;

  /// The most room it may take (the bigger size shrinks to fit, e.g. in landscape).
  final double maxSide;

  /// Brighter than the map screen's dark colours: it sits on a camera picture.
  static const palette = MapPalette(background: Color(0xFF0B1218), floor: Color(0xFF3A5068),
    wall: Color(0xFFF2F6FA), cost: Color(0xFF4F7FAE));

  /// Map metres per side of the small view.
  static const smallSpan = 6.0;

  @override
  State<MiniMap> createState() => MiniMapState();
}

class MiniMapState extends State<MiniMap> with ThrottledRebuild {
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 100);
  late final RosClient _ros = RosClient(widget.connection);
  final _subs = <StreamSubscription<Map<String, dynamic>>>[];
  final tf = TfTree();

  /// False until a map has arrived: until then nothing is shown.
  bool get hasMap => _cells.isNotEmpty;
  bool big = false;
  bool view3d = false;
  bool _modeTouched = false;

  List<int> _cells = const [];
  int _width = 0, _height = 0;
  double _resolution = 0.05;
  Pose2D _origin = Pose2D.identity;
  String _mapFrame = 'map';
  ui.Image? _image;
  int _generation = 0;

  Pose2D? _odom;
  String _odomFrame = 'odom', _baseFrame = '';

  @override
  void initState() {
    super.initState();
    if (widget.allow3d) _loadMode();
    _start();
  }

  Future<void> _loadMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted && !_modeTouched) setState(() => view3d = prefs.getBool(MiniMap.homeViewKey) ?? false);
    } catch (_) {}
  }

  Future<void> _setMode(bool value) async {
    _modeTouched = true;
    setState(() => view3d = value);
    try { await (await SharedPreferences.getInstance()).setBool(MiniMap.homeViewKey, value); } catch (_) {}
  }

  Future<void> _start() async {
    if (widget.onSnapshot != null) {
      _snapshotTimer = Timer.periodic(const Duration(seconds: 5), (_) => _snapshot());
    }
    try {
      final caps = await (widget.capabilities?.call() ?? RobotCapabilities.discover(widget.connection));
      if (!mounted) return;
      final ns = widget.namespace;
      final map = await caps.pick('nav_msgs/OccupancyGrid', 'map');
      if (map == null || !mounted) return; // no map: no mini map
      final odom = await caps.pick('nav_msgs/Odometry', 'odom') ?? '$ns/odom';
      final tfTopic = await caps.pick('tf2_msgs/TFMessage', 'tf') ?? '$ns/tf';
      final tfStatic = caps.topicsOfType('tf2_msgs/TFMessage').where((t) => t.endsWith('tf_static')).firstOrNull;
      if (!mounted) return;
      _subs
        ..add(_ros.subscribe(map, throttleRate: 3000).listen(_onMap, onError: (_) {}))
        ..add(_ros.subscribe(odom, throttleRate: 100).listen(_onOdom, onError: (_) {}))
        // TF mixes fast wheel/odom transforms and slower map->odom updates. Throttling whole
        // messages can discard the latter forever, leaving a stationary robot without a map pose.
        ..add(_ros.subscribe(tfTopic).listen(_onTf, onError: (_) {}));
      if (tfStatic != null) _subs.add(_ros.subscribe(tfStatic).listen(_onTf, onError: (_) {}));
    } catch (_) {
      // The driving screen works without it.
    }
  }

  void _onMap(Map<String, dynamic> msg) {
    try {
      final info = msg['info'] as Map;
      final width = info['width'] as int, height = info['height'] as int;
      final cells = List<int>.from(msg['data'] as List);
      final res = (info['resolution'] as num).toDouble();
      if (width <= 0 || height <= 0 || res <= 0 || !res.isFinite || cells.length != width * height) return;
      final o = info['origin'] as Map;
      _cells = cells;
      _width = width;
      _height = height;
      _resolution = res;
      _origin = Pose2D((o['position']['x'] as num).toDouble(), (o['position']['y'] as num).toDouble(),
          yawOf(o['orientation'] as Map));
      _mapFrame = TfTree.clean((msg['header'] as Map)['frame_id'] as String);
      widget.places?.observeMap(PlaceBook.mapKey(frame: _mapFrame, width: width, height: height, resolution: res,
          originX: _origin.x, originY: _origin.y));
      _raster();
    } catch (_) {}
  }

  void _raster() {
    final generation = ++_generation;
    final pixels = Uint8List(_width * _height * 4);
    final lut = MiniMap.palette.rgbaTable();
    for (var row = 0; row < _height; row++) {
      var i = (_height - 1 - row) * _width * 4; // ROS row 0 is the bottom of the map
      var cell = row * _width;
      for (var col = 0; col < _width; col++, cell++, i += 4) {
        final v = _cells[cell];
        final k = (v < -1 || v > 100 ? 50 : v + 1) * 4;
        pixels[i] = lut[k];
        pixels[i + 1] = lut[k + 1];
        pixels[i + 2] = lut[k + 2];
        pixels[i + 3] = lut[k + 3];
      }
    }
    ui.decodeImageFromPixels(pixels, _width, _height, ui.PixelFormat.rgba8888, (image) {
      if (!mounted || generation != _generation) {
        image.dispose();
        return;
      }
      final previous = _image;
      setState(() => _image = image);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    });
  }

  void _onOdom(Map<String, dynamic> msg) {
    try {
      final p = msg['pose']['pose'];
      _odom = Pose2D((p['position']['x'] as num).toDouble(), (p['position']['y'] as num).toDouble(),
          p['orientation'] is Map ? yawOf(p['orientation'] as Map) : 0);
      _odomFrame = TfTree.clean(msg['header']['frame_id'] as String);
      _baseFrame = TfTree.clean('${msg['child_frame_id'] ?? ''}');
      if (hasMap) rebuildSoon();
    } catch (_) {}
  }

  void _onTf(Map<String, dynamic> msg) {
    try {
      var changed = false;
      for (final t in msg['transforms'] as List) {
        changed = tf.add(t as Map) || changed;
      }
      if (changed && hasMap) rebuildSoon();
    } catch (_) {}
  }

  /// The robot in the map frame, as the map screen finds it (TF chain, else odometry and map→odom).
  Pose2D? get robotPose {
    for (final base in [if (_baseFrame.isNotEmpty) _baseFrame, 'base_footprint', 'base_link']) {
      if (!tf.has(base)) continue;
      final viaTf = tf.lookup(_mapFrame, base);
      if (viaTf != null) return viaTf;
    }
    final odom = _odom;
    if (odom == null) return null;
    if (_odomFrame == _mapFrame) return odom;
    return tf.lookup(_mapFrame, _odomFrame)?.compose(odom);
  }

  /// The home map moved by the person: 2D pan and zoom, or the 3D view's own camera.
  bool _moved = false;
  Offset _pan = Offset.zero;
  double _zoom = 1, _zoomStart = 1;
  final _view3dKey = GlobalKey<Map3DViewState>();

  void _recenter() => setState(() {
    _moved = false;
    _pan = Offset.zero;
    _zoom = 1;
    _view3dKey.currentState?.followAgain();
  });

  Timer? _snapshotTimer;
  Pose2D? _snapshotPose;
  ui.Image? _snapshotMap;

  /// The view as a picture for the widget: dark rounded square, map turned so the robot points up.
  Future<void> _snapshot() async {
    final send = widget.onSnapshot, pose = robotPose, img = _image;
    if (send == null || pose == null || img == null) return;
    final last = _snapshotPose;
    final moved = last == null || identical(_snapshotMap, img) == false ||
        math.sqrt(math.pow(pose.x - last.x, 2) + math.pow(pose.y - last.y, 2)) > 0.05 || (pose.yaw - last.yaw).abs() > 0.05;
    if (!moved) return;
    _snapshotPose = pose;
    _snapshotMap = img;
    const s = MiniMap.snapshotSize;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final r = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, s * 1.0, s * 1.0), const Radius.circular(36));
    canvas.clipRRect(r);
    canvas.drawRect(const Rect.fromLTWH(0, 0, s * 1.0, s * 1.0), Paint()..color = MiniMap.palette.background);
    MiniMapPainter(image: img, width: _width, height: _height, resolution: _resolution, origin: _origin,
        robot: pose, pixelsPerMetre: s / 5.0, markerScale: 2.6).paint(canvas, const Size(s * 1.0, s * 1.0));
    final picture = recorder.endRecording();
    try {
      final image = await picture.toImage(s, s);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data != null && mounted) send(data.buffer.asUint8List(), pose);
    } catch (_) {
      // Drawing can fail with the app in the background; the widget keeps the last picture.
    } finally {
      picture.dispose();
    }
  }

  @override
  void dispose() {
    _snapshotTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _ros.dispose();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!hasMap) return const SizedBox.shrink();
    final side = math.max(96.0, math.min(big ? 220.0 : 128.0, widget.maxSide));
    final strip = widget.height;
    final pose = robotPose;
    // The home map (a strip) can be moved; the small overlay on the driving screen only resizes on a tap.
    final movable = strip != null;
    final ppm = (strip == null ? 128 / MiniMap.smallSpan : math.max(128 / MiniMap.smallSpan, strip / 8)) * _zoom;
    return Semantics(label: context.strings.mapAroundRobot, button: true, child: GestureDetector(
      key: const Key('mini-map'),
      onTap: widget.onTap ?? () => setState(() => big = !big),
      child: AnimatedContainer(duration: const Duration(milliseconds: 180),
        width: strip == null ? side : double.infinity, height: strip ?? side,
        decoration: BoxDecoration(color: MiniMap.palette.background.withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [Positioned.fill(child: pose == null
            ? Center(child: Padding(padding: const EdgeInsets.all(8), child: Text(context.strings.findRobotOnMap,
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontSize: 11))))
            : widget.allow3d && view3d
                ? IgnorePointer(ignoring: !movable, child: KeyedSubtree(key: const Key('home-map-3d'),
                    child: Map3DView(key: _view3dKey, image: _image, cells: _cells,
                    width: _width, height: _height, resolution: _resolution, origin: _origin, robot: pose,
                    overview: true, movable: movable, onMoved: () => setState(() => _moved = true),
                    background: MiniMap.palette.background, wallColor: MiniMap.palette.wall)))
                : GestureDetector(
                    // Drag to look around, pinch to zoom; a plain tap still opens the full map.
                    onScaleStart: movable ? (_) => _zoomStart = _zoom : null,
                    onScaleUpdate: movable ? (d) => setState(() {
                      _moved = true;
                      _pan += d.focalPointDelta;
                      if (d.pointerCount > 1) _zoom = (_zoomStart * d.scale).clamp(0.4, 4.0);
                    }) : null,
                    child: CustomPaint(painter: MiniMapPainter(image: _image, width: _width, height: _height,
                      resolution: _resolution, origin: _origin, robot: pose, pixelsPerMetre: ppm, pan: _pan)))),
          // Back to the robot after the person moved the view.
          if (movable && _moved) Positioned(right: 8, bottom: 8, child: Material(
            // Outlined like the 2D/3D switch, so it shows on the dark map in a dark theme too.
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
            shape: CircleBorder(side: BorderSide(color: Theme.of(context).colorScheme.outline)),
            child: IconButton(key: const Key('home-map-recenter'), tooltip: context.strings.mapRecenter,
              icon: const Icon(Icons.gps_fixed), onPressed: _recenter))),
          if (widget.allow3d) Positioned(top: 8, right: 8, child: Material(
            color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.94),
            borderRadius: BorderRadius.circular(12),
            child: SegmentedButton<bool>(key: const Key('home-map-mode'), showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [ButtonSegment(value: false, label: Text('2D')), ButtonSegment(value: true, label: Text('3D'))],
              selected: {view3d}, onSelectionChanged: (values) => _setMode(values.single)))),
        ]),
      ),
    ));
  }
}

/// The map turned so the robot points up, centred on the robot.
class MiniMapPainter extends CustomPainter {
  MiniMapPainter({required this.image, required this.width, required this.height, required this.resolution,
    required this.origin, required this.robot, required this.pixelsPerMetre, this.markerScale = 1,
    this.pan = Offset.zero});

  final ui.Image? image;
  final int width, height;
  final double resolution, pixelsPerMetre;
  /// Size of the robot arrow (a picture shown small, like the widget's, needs a bigger one).
  final double markerScale;
  /// How far the person dragged the view away from the robot (screen pixels).
  final Offset pan;
  final Pose2D origin, robot;

  /// Where map point (x, y) is drawn in a view of [size] (for tests and the painter alike).
  static Offset toScreen(double x, double y, Pose2D robot, double ppm, Size size) {
    final dx = x - robot.x, dy = y - robot.y;
    // Turn by (90° - yaw) so the robot's heading is "up", then flip y (screen y grows downwards).
    final a = math.pi / 2 - robot.yaw, c = math.cos(a), s = math.sin(a);
    final rx = dx * c - dy * s, ry = dx * s + dy * c;
    return Offset(size.width / 2 + rx * ppm, size.height / 2 - ry * ppm);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final img = image;
    if (img != null) {
      canvas.save();
      canvas.translate(size.width / 2 + pan.dx, size.height / 2 + pan.dy);
      canvas.scale(pixelsPerMetre, -pixelsPerMetre); // y up, in metres
      canvas.rotate(math.pi / 2 - robot.yaw);
      canvas.translate(-robot.x, -robot.y);
      canvas.translate(origin.x, origin.y);
      canvas.rotate(origin.yaw);
      canvas.scale(resolution, -resolution); // image rows run down; map rows run up
      canvas.drawImage(img, Offset(0, -height.toDouble()), Paint()..filterQuality = FilterQuality.none);
      canvas.restore();
    }
    // The robot: an arrow in the middle, pointing up.
    final c = Offset(size.width / 2 + pan.dx, size.height / 2 + pan.dy), k = markerScale;
    canvas.drawCircle(c, 11 * k, Paint()..color = const Color(0x553D8BFF));
    final arrow = Path()
      ..moveTo(c.dx, c.dy - 9 * k)
      ..lineTo(c.dx + 6.5 * k, c.dy + 7 * k)
      ..lineTo(c.dx, c.dy + 3.5 * k)
      ..lineTo(c.dx - 6.5 * k, c.dy + 7 * k)
      ..close();
    canvas.drawPath(arrow, Paint()..color = const Color(0xFF3D8BFF));
    canvas.drawPath(arrow, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5 * k);
  }

  @override
  bool shouldRepaint(MiniMapPainter old) => old.image != image || old.robot != robot || old.pan != pan ||
      old.pixelsPerMetre != pixelsPerMetre || old.origin != origin;
}
