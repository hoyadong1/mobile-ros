import 'app_language.dart';
import 'dart:async';
import 'tool_tabs.dart';
import 'package:material_ui/material_ui.dart';

import 'controllers/navigation_controller.dart';
import 'map_geometry.dart';
import 'map_page.dart' show MapPainter, MapPalette;
import 'robot_capabilities.dart';
import 'robot_session.dart';
import 'ros_client.dart';

/// A read-only view of robots on one ROS connection. Only poses explicitly reported in the map
/// frame are drawn; odometry from separate robot frames cannot safely share one map.
class FleetOverviewPage extends StatefulWidget {
  const FleetOverviewPage({super.key, required this.sessions});
  final List<RobotSession> sessions;

  @override
  State<FleetOverviewPage> createState() => _FleetOverviewPageState();
}

class _FleetOverviewPageState extends State<FleetOverviewPage> {
  late final RosClient _ros = RosClient(widget.sessions.first.connection);
  final _subscriptions = <StreamSubscription<Map<String, dynamic>>>[];
  final _poses = <String, Pose2D>{};
  final _batteries = <String, double>{};
  List<int> _cells = const [];
  int _width = 0, _height = 0;
  double _resolution = 1;
  Pose2D _origin = Pose2D.identity;
  String _mapFrame = 'map';
  String? _error;
  // What is already subscribed, so a later look adds only what was missing.
  bool _hasMap = false;
  final _posed = <String>{}, _powered = <String>{};
  Timer? _retry;
  int _looks = 0;

  @override
  void initState() {
    super.initState();
    for (final session in widget.sessions) {
      session.nav.addListener(_refreshStatus);
      session.drive.addListener(_refreshStatus);
    }
    _listen();
  }

  void _refreshStatus() {
    if (mounted) setState(() {});
  }

  /// Finds the map and each robot's pose and battery topics. Looks again every few seconds (for two
  /// minutes) while the map or a robot's pose is missing: a robot's topics may not be known yet when the
  /// screen opens (a direct Zenoh connection learns the graph over a few seconds; found with four robots,
  /// where one robot stayed "Unknown" for good), or its localization may start later.
  Future<void> _listen() async {
    _looks++;
    try {
      final all = await RobotCapabilities.discover(widget.sessions.first.connection);
      if (!mounted) return;
      _subscribeTo(all);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    final missing = !_hasMap || widget.sessions.any((s) => !_posed.contains(s.name));
    if (mounted && missing && _looks < 40) _retry = Timer(const Duration(seconds: 3), _listen);
  }

  void _subscribeTo(RobotCapabilities all) {
    final mapTopics = all.topicsOfType('nav_msgs/OccupancyGrid');
    // The site map: /map, else a robot's own map (/robot1/map); a costmap only when nothing else exists.
    final mapTopic = mapTopics.contains('/map') ? '/map'
        : mapTopics.where((t) => t.endsWith('/map')).firstOrNull
          ?? mapTopics.where((t) => !t.contains('costmap')).firstOrNull ?? mapTopics.firstOrNull;
    if (mapTopic != null && !_hasMap) {
      _hasMap = true;
      _subscriptions.add(_ros.subscribe(mapTopic, throttleRate: 1000).listen(_onMap));
    }
    for (final session in widget.sessions) {
      final name = session.name;
      final caps = all.scoped(session.namespace, all.robotNamespaces());
      final poseTopics = caps.topicsOfType('geometry_msgs/PoseWithCovarianceStamped');
      final poseTopic = poseTopics.where((t) => t.endsWith('/amcl_pose')).firstOrNull ??
          poseTopics.where((t) => t.endsWith('/map_pose')).firstOrNull;
      if (poseTopic != null && _posed.add(name)) {
        _subscriptions.add(_ros.subscribe(poseTopic, throttleRate: 500).listen(
          (msg) => _onPose(name, msg)));
      }
      final batteryTopic = caps.topicsOfType('sensor_msgs/BatteryState').firstOrNull;
      if (batteryTopic != null && _powered.add(name)) {
        _subscriptions.add(_ros.subscribe(batteryTopic, throttleRate: 1000).listen((msg) {
          final value = msg['percentage'];
          if (!mounted || value is! num || !value.isFinite || value < 0) return;
          setState(() => _batteries[name] = value.toDouble());
        }));
      }
    }
  }

  void _onMap(Map<String, dynamic> msg) {
    try {
      final info = msg['info'] as Map;
      final width = info['width'] as int, height = info['height'] as int;
      final cells = List<int>.from(msg['data'] as List);
      final resolution = (info['resolution'] as num).toDouble();
      if (width <= 0 || height <= 0 || resolution <= 0 || cells.length != width * height) {
        throw const FormatException('Invalid map');
      }
      final origin = info['origin'] as Map;
      final position = origin['position'] as Map;
      final full = Pose2D((position['x'] as num).toDouble(), (position['y'] as num).toDouble(),
          yawOf(origin['orientation'] as Map));
      // Only the known part (and a metre around it): a SLAM grid is mostly unknown space.
      final crop = cropToKnown(cells, width, height, margin: (1 / resolution).ceil());
      final corner = full.apply(crop.left * resolution, crop.bottom * resolution);
      setState(() {
        _cells = crop.cells;
        _width = crop.width;
        _height = crop.height;
        _resolution = resolution;
        _origin = Pose2D(corner.x, corner.y, full.yaw);
        _mapFrame = TfTree.clean((msg['header'] as Map)['frame_id'] as String);
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Map data error: $e');
    }
  }

  void _onPose(String name, Map<String, dynamic> msg) {
    try {
      final frame = TfTree.clean((msg['header'] as Map)['frame_id'] as String);
      if (frame != _mapFrame) return;
      final pose = msg['pose'] as Map;
      final body = pose['pose'] as Map;
      final position = body['position'] as Map;
      final x = (position['x'] as num).toDouble(), y = (position['y'] as num).toDouble();
      if (!x.isFinite || !y.isFinite || !mounted) return;
      setState(() => _poses[name] = Pose2D(x, y, yawOf(body['orientation'] as Map)));
    } catch (_) {
      // An incomplete pose should not move a marker.
    }
  }

  @override
  void dispose() {
    _retry?.cancel();
    for (final session in widget.sessions) {
      session.nav.removeListener(_refreshStatus);
      session.drive.removeListener(_refreshStatus);
    }
    for (final sub in _subscriptions) { sub.cancel(); }
    _ros.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        title: Text(ToolTabsScope.maybeOf(context)?.title ?? context.strings.fleetOverview),
        bottom: ToolTabsScope.maybeOf(context)?.bar),
    body: ListView(padding: const EdgeInsets.all(20), children: [
      if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      Wrap(spacing: 12, runSpacing: 12, children: [
        // Full width on a phone, side by side on a tablet.
        for (final session in widget.sessions) SizedBox(
            width: MediaQuery.sizeOf(context).width < 600 ? double.infinity : 280, child: _card(session)),
      ]),
      const SizedBox(height: 20),
      Text(context.strings.fleetMapTitle, style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      if (_width == 0) Card(child: Padding(padding: const EdgeInsets.all(24),
        child: Text(context.strings.fleetWaitingMap)))
      else ClipRRect(borderRadius: BorderRadius.circular(16), child: ColoredBox(
        color: MapPalette.of(context).background,
        child: AspectRatio(aspectRatio: _width / _height, child: CustomPaint(
          key: const Key('fleet-map'),
          painter: MapPainter(image: null, mapData: _cells, width: _width, height: _height,
            resolution: _resolution, origin: _origin, robot: null, goal: null, palette: MapPalette.of(context),
            fleetRobots: [for (final entry in _poses.entries) (entry.key, entry.value)]),
        )))),
    ]),
  );

  Widget _card(RobotSession session) {
    final name = session.name;
    final pose = _poses[name];
    final battery = _batteries[name];
    final status = session.nav.status;
    final task = status == NavStatus.active ? context.strings.navActive
      : session.drive.source == null ? context.strings.idle : context.strings.driving(session.drive.source!.name);
    final error = session.drive.lastError ??
        (status == NavStatus.failed ? context.strings.navigationFailed : session.connection.lastError);
    return Card(key: Key('fleet-$name'), child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(session.label, style: Theme.of(context).textTheme.titleMedium),
        if (session.label != name) Text(name, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
        Text(context.strings.fleetBattery(battery == null ? context.strings.unknown : '${(battery * 100).round()}%')),
        Text(context.strings.fleetPosition(pose == null ? context.strings.unknown
          : '${pose.x.toStringAsFixed(1)}, ${pose.y.toStringAsFixed(1)} m')),
        Text(context.strings.fleetTask(task)),
        Text(context.strings.fleetError(error ?? context.strings.none)),
      ])));
  }
}
