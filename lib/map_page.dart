import 'app_language.dart';
import 'relay_messages.dart';
import 'dart:async';
import 'app_theme.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:material_ui/material_ui.dart';
import 'ros_connection.dart';
import 'cloud_session.dart' show CloudRosConnection;
import 'map_geometry.dart';
import 'navigation_goal.dart';
import 'map_topics.dart';
import 'places.dart';
import 'robot_capabilities.dart';
import 'topic_discovery.dart';
import 'widgets/throttled_rebuild.dart';
import 'controllers/navigation_controller.dart';
import 'ros_client.dart';
import 'package:flutter/foundation.dart' show compute;
import 'relocalize.dart';
import 'map3d.dart';
import 'dart:io' show Directory;
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'controllers/drive_controller.dart';
import 'drive_command.dart';
import 'mapping.dart';
import 'costmap_layer.dart';
import 'nav_activity.dart';
import 'nav_tools.dart';
import 'patrol.dart';
import 'nav_activity_text.dart';
import 'robot_profile.dart';
import 'widgets/control_stick.dart';
import 'robot_log.dart';
import 'log_page.dart';

export 'controllers/navigation_controller.dart' show NavMode;

enum NavState { idle, preview, active, succeeded, canceled, failed }

enum MapTool { goal, setPose }

/// Full-screen map: pinch/drag to look around, tap (or press-and-drag for heading) to set a goal, live
/// progress and cancel through Nav2, planned path and LiDAR overlays, and AMCL initial pose.
class MapVisualizationPage extends StatefulWidget {
  final String ip;
  final String port;
  final RosConnection Function(String, String) connectionFactory;

  /// The session's shared discovery (see [RobotSession.capabilities]); without it the page
  /// discovers on its own connection.
  final Future<RobotCapabilities> Function()? capabilities;

  /// The session's navigation controller, shared with the AI agent: a goal keeps running (and stays
  /// visible when the page reopens) after the page closes. Without it the page makes its own.
  final NavigationController? nav;

  /// The session's saved places (shared with the AI assistant); without it the page keeps its own.
  final PlaceBook? places;

  /// Which robot on the connection (`/robot1`), '' for a robot at the root. Topic choices are saved per robot.
  final String namespace;

  /// Where this robot's choices are saved (RobotSession.storeAddress); its address when not given.
  final String? storeAddress;
  String get savedAs => storeAddress ?? '$ip:$port$namespace';

  /// Opens in "Make a map": the map grows as the robot drives (SLAM on the robot); a stick to drive, the
  /// area mapped so far, and saving. No Set pose (the mapper knows where the robot is). The page switches
  /// between this and navigating itself, and opens in it when the robot runs a mapping program.
  final bool mapping;
  final bool initial3d;
  final RobotLog? robotLog;

  /// Drives the robot with the stick in [mapping] mode (the session's controller), after [prepare].
  final DriveController? drive;
  final Future<void> Function()? prepare;

  /// Where maps are kept on the phone (default: the app's documents folder, `maps/`).
  final Future<Directory> Function()? mapFolder;

  const MapVisualizationPage({required this.ip, required this.port, super.key,
    this.connectionFactory = RosConnection.new, this.capabilities, this.nav, this.places, this.namespace = '', this.storeAddress,
    this.mapping = false, this.drive, this.prepare, this.mapFolder, this.initial3d = false, this.robotLog});

  @override
  State<MapVisualizationPage> createState() => MapPageState();
}

class MapPageState extends State<MapVisualizationPage> with ThrottledRebuild {
  /// Robot pose, TF, scan and plan updates redraw the map at most this often (~20 fps).
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 50);

  static const cellPx = 4.0; // map pixels per grid cell inside the zoomable canvas

  RosConnection? connection;
  bool get limitedRemote => connection is CloudRosConnection;
  String? errorMessage;
  RosVersion? rosVersion; // null until detected; goals are blocked until then
  RosClient? _ros;
  /// Sends and follows goals; this page shows its state and adds the preview step before Go.
  NavigationController? nav;
  NavMode get navMode => nav?.mode ?? NavMode.goalPose;

  // occupancy grid
  List<int> mapData = [];
  int mapWidth = 0, mapHeight = 0;
  double resolution = 0.05;
  Pose2D origin = Pose2D.identity;
  String mapFrame = 'map';
  ui.Image? mapImage;
  int _mapImageGeneration = 0;
  Rect knownCells = Rect.zero;

  // robot
  final tf = TfTree();
  Pose2D? odomPose; // base in the odom frame, from /odom
  String odomFrame = 'odom', baseFrame = '';

  // overlays
  String? planTopic, scanTopic;
  String mapTopic = '/map', odomTopic = '/odom';
  String tfTopic = '/tf', tfStaticTopic = '/tf_static';
  String _initialPoseTopic = initialPoseTopic;
  String? _moveBaseAction; // a move_base action server found by discovery (ROS 1)
  Map<MapSlot, String?> automaticTopics = {};

  /// Discovery finished (so "no map topic" means the robot really has none).
  bool _discovered = false;

  /// A map topic is set but nothing arrived for a while.
  bool mapSlow = false;
  Timer? _mapSlowTimer;
  Map<MapSlot, String> topicOverrides = {};
  Map<String, dynamic>? _topicsInfo;
  List<String> _actionNames = [];
  Set<String> _subscribed = {};
  final Map<String, String> _advertised = {};
  bool showPath = true, showScan = true;

  /// Nav2's costmaps over the map (Layers menu): off until asked for, because they arrive as a grid every
  /// second or so. The topic is the robot's own, found by name among its OccupancyGrid topics.
  final costmapTopics = <CostmapKind, String?>{};
  final showCostmap = <CostmapKind, bool>{CostmapKind.local: false, CostmapKind.global: false};
  final _costmaps = <CostmapKind, Costmap?>{};
  final _costmapImages = <CostmapKind, ui.Image?>{};
  final _costmapTooLarge = <CostmapKind>{};
  List<math.Point<double>> path = [];
  List<math.Point<double>> scanPoints = [];

  // goal / navigation
  MapTool tool = MapTool.goal;
  Pose2D? goal;
  NavState navState = NavState.idle;
  double? get distanceRemaining => nav?.distanceRemaining;
  double? get etaSeconds => nav?.etaSeconds;
  double? get _startDistance => nav?.startDistance; // for the progress bar
  int get recoveries => nav?.recoveries ?? 0;
  NavActivity? get navActivity => nav?.activity;
  String? get resultDetail => nav?.detail;
  Offset? _dragAnchor; // long-press start (canvas coordinates)
  double? _dragYaw;

  // view
  final viewer = TransformationController();
  Size _viewport = Size.zero;
  bool _fitted = false;
  final GlobalKey _canvasKey = GlobalKey();

  /// Named destinations for this robot.
  late final PlaceBook placeBook = widget.places ?? PlaceBook('${widget.ip}:${widget.port}');

  @override
  void initState() {
    super.initState();
    placeBook.addListener(_onPlaces);
    if (!placeBook.loaded) placeBook.load();
    connect();
  }

  void _onPlaces() {
    if (mounted) setState(() {});
  }

  /// Names the previewed goal and keeps it as a place.
  Future<void> savePlace(Pose2D at) async {
    final name = await showDialog<String>(context: context, builder: (_) => const _PlaceNameDialog());
    if (name == null || name.trim().isEmpty || !mounted) return;
    await placeBook.save(Place(name.trim(), at.x, at.y, yaw: at.yaw, frame: mapFrame));
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(context.strings.placeSaved(name.trim()))));
  }

  /// The map file last saved on the robot from here: what a floor made now would load.
  String? _savedOnRobot;
  Future<String?>? _loader;
  bool switchingFloor = false;

  /// A round through several saved places (Nav2 FollowWaypoints), when the robot has that action.
  PatrolController? patrol;

  /// Which places the person ticked for a patrol, in the order they ticked them.
  Future<void> _openPatrolSetup() async {
    final places = [for (final p in placeBook.usable) if (p.frame == mapFrame) p];
    final chosen = <String>[];
    var loop = false;
    final go = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, showDragHandle: true,
      builder: (sheet) => StatefulBuilder(builder: (sheet, setSheet) {
        final s = sheet.strings;
        // Everything but the button scrolls, so a short sheet (large text) still reaches every place.
        return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Flexible(child: ListView(shrinkWrap: true, children: [
              Text(s.patrol, style: Theme.of(sheet).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(s.patrolPickPlaces, style: TextStyle(color: sheet.muted)),
              const SizedBox(height: 8),
              for (final p in places) CheckboxListTile(key: Key('patrol-pick-${p.name}'), dense: true,
                value: chosen.contains(p.name), controlAffinity: ListTileControlAffinity.leading,
                title: Text(p.name),
                secondary: chosen.contains(p.name) ? CircleAvatar(radius: 12, child: Text('${chosen.indexOf(p.name) + 1}')) : null,
                onChanged: (v) => setSheet(() => v == true ? chosen.add(p.name) : chosen.remove(p.name))),
              SwitchListTile(key: const Key('patrol-loop'), dense: true, contentPadding: EdgeInsets.zero,
                title: Text(s.patrolLoop), value: loop, onChanged: (v) => setSheet(() => loop = v)),
            ])),
            Align(alignment: Alignment.centerRight, child: FilledButton.icon(key: const Key('patrol-start'),
              icon: const Icon(Icons.route), label: Text(chosen.length < 2 ? s.patrolNeedTwo : s.patrolStart),
              onPressed: chosen.length < 2 ? null : () => Navigator.pop(sheet, true))),
          ])));
      }));
    if (go != true || !mounted) return;
    final stops = [for (final name in chosen) PatrolStop(name, places.firstWhere((p) => p.name == name).pose)];
    nav?.cancel(); // one thing at a time: a single trip and a round would pull the robot two ways
    setState(() { goal = null; navState = NavState.idle; });
    try {
      unawaited(patrol!.start(stops, frame: mapFrame, loop: loop));
    } catch (e) {
      setState(() => errorMessage = context.strings.sendGoalFailed('$e'));
    }
  }

  Widget _patrolCard(TextStyle title, TextStyle sub) {
    final p = patrol!, s = context.strings;
    if (p.isRunning) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.patrol.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w700, color: context.muted)),
            Text(s.patrolHeadingFor(p.currentName ?? '', p.current + 1, p.stops.length), key: const Key('patrol-progress'), style: title),
            if (p.loop) Text(s.patrolRound(p.laps + 1), style: sub),
          ])),
          FilledButton.icon(key: const Key('patrol-stop'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E), foregroundColor: Colors.white,
              visualDensity: VisualDensity.compact),
            onPressed: p.cancel, icon: const Icon(Icons.stop, size: 18), label: Text(s.cancel)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: p.stops.isEmpty ? null : p.current / p.stops.length, minHeight: 6)),
      ]);
    }
    final (icon, color, text) = switch (p.status) {
      PatrolStatus.finished => (Icons.check_circle, const Color(0xFF2E7D32), s.patrolFinished),
      PatrolStatus.canceled => (Icons.cancel_outlined, Colors.blueGrey, s.patrolStopped),
      _ => (Icons.error, const Color(0xFFB3261E), s.patrolFailed),
    };
    final missed = [for (final i in p.missed) if (i >= 0 && i < p.stops.length) p.stops[i].name];
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(icon, color: color), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(text, key: const Key('patrol-result'), style: title),
          if (missed.isNotEmpty) Text(s.patrolMissed(missed.join(', ')), style: sub),
          if (p.detail != null) Text(p.detail!, style: sub),
        ])),
      ]),
      Align(alignment: Alignment.centerRight, child: TextButton(key: const Key('patrol-dismiss'),
        onPressed: p.reset, child: Text(s.ok))),
    ]);
  }

  /// What Nav2 offers to un-stick the robot (clear the costmaps), looked up once the robot is connected.
  NavTools navTools = NavTools.none;
  bool clearingCostmaps = false;

  Future<void> _findNavTools(RosConnection client) async {
    final found = navToolsIn(await robotServices(client), namespace: widget.namespace);
    if (mounted) setState(() => navTools = found);
  }

  /// Clears what the costmaps remember, so Nav2 plans again on what the robot sees now.
  Future<void> clearCostmapsNow() async {
    final ros = _ros ??= RosClient(connection!);
    final s = context.strings;
    setState(() => clearingCostmaps = true);
    String message;
    try {
      await clearCostmaps(ros, navTools);
      message = s.costmapsCleared;
    } catch (_) {
      message = s.costmapsClearFailed;
    }
    if (!mounted) return;
    setState(() => clearingCostmaps = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _clearCostmapsButton() => TextButton.icon(
    key: const Key('nav-clear-costmaps'),
    icon: clearingCostmaps
        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(Icons.cleaning_services_outlined, size: 18),
    label: Text(context.strings.clearObstacleMemory),
    onPressed: clearingCostmaps ? null : clearCostmapsNow);

  /// The robot's map loader (Nav2 map_server), looked up once.
  Future<String?> get mapLoader => _loader ??= () async {
    final client = connection;
    if (client == null) return null;
    return loadMapService(await robotServices(client), namespace: widget.namespace);
  }();

  /// Names the map shown now as a floor of the building, with the map file that loads it.
  Future<void> _nameFloor() async {
    final key = placeBook.currentMap;
    final now = key == null ? null : placeBook.floors[key];
    final result = await showDialog<(String, String)>(context: context,
        builder: (_) => _FloorNameDialog(now?.name ?? '', now?.mapFile ?? _savedOnRobot ?? ''));
    if (result == null) return;
    await placeBook.nameFloor(result.$1, mapFile: result.$2);
  }

  /// The building's floors: name this one, or load another floor's map on the robot.
  Future<void> showFloors() async {
    final loader = await mapLoader;
    if (!mounted) return;
    final target = await showModalBottomSheet<String>(context: context, showDragHandle: true,
      builder: (context) => ListenableBuilder(listenable: placeBook, builder: (context, _) {
        final here = placeBook.currentMap;
        final others = [for (final e in placeBook.floors.entries) if (e.key != here) e];
        final busy = navState == NavState.active;
        return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.strings.floors, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(height: 8),
            ListTile(key: const Key('floor-here'), contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.my_location),
              title: Text(placeBook.floor ?? context.strings.noFloorName),
              subtitle: Text(placeBook.floors[here]?.mapFile ?? context.strings.mapShownNow),
              trailing: TextButton(onPressed: here == null ? null : () async {
                Navigator.pop(context);
                await _nameFloor();
              }, child: Text(placeBook.floor == null ? context.strings.name : 'Edit'))),
            for (final e in others) ListTile(key: Key('floor-${e.value.name}'), contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.layers_outlined),
              title: Text(e.value.name),
              subtitle: Text(e.value.mapFile == null ? context.strings.noMapFileFloor
                  : loader == null ? context.strings.noMapLoader
                  : busy ? context.strings.finishTripFirst : e.value.mapFile!),
              trailing: FilledButton.tonal(key: Key('floor-switch-${e.value.name}'),
                onPressed: e.value.mapFile == null || loader == null || busy || switchingFloor ? null
                    : () => Navigator.pop(context, e.key),
                child: Text(context.strings.switchFloor))),
            if (others.isEmpty) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(context.strings.floorsHelp,
                style: TextStyle(color: context.muted))),
          ])));
      }));
    if (target != null && loader != null && mounted) await switchFloor(target, loader);
  }

  /// Loads another floor's map on the robot, then asks where the robot is on it.
  Future<void> switchFloor(String key, String loader) async {
    final floor = placeBook.floors[key];
    final file = floor?.mapFile;
    if (floor == null || file == null || navState == NavState.active || switchingFloor) return;
    setState(() { switchingFloor = true; errorMessage = null; });
    try {
      await loadMapOnRobot(_ros ??= RosClient(connection!), loader, file);
      // The new map comes on the map topic; it is recognised as that floor.
      for (var i = 0; i < 50 && mounted && placeBook.currentMap != key; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } catch (e) {
      if (mounted) setState(() => errorMessage = e is StateError ? e.message : context.strings.loadFloorError(floor.name, '$e'));
      return;
    } finally {
      if (mounted) setState(() => switchingFloor = false);
    }
    if (!mounted) return;
    if (placeBook.currentMap != key) {
      setState(() => errorMessage = context.strings.floorNotArrived(floor.name));
    }
    await _whereNow(floor.name);
  }

  /// After a floor change localization does not know where the robot is: a saved place, or the map.
  Future<void> _whereNow(String floor) async {
    final places = [for (final p in placeBook.usable) if (p.frame == mapFrame) p];
    final chosen = await showModalBottomSheet<Object>(context: context, showDragHandle: true,
      builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.strings.onFloorWhere(floor), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
          const SizedBox(height: 4),
          Text(context.strings.localizeHint, style: TextStyle(color: context.muted)),
          const SizedBox(height: 8),
          for (final p in places) ListTile(key: Key('where-${p.name}'), contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.place_outlined, color: Color(0xFF6A1B9A)), title: Text(context.strings.atPlace(p.name)),
            onTap: () => Navigator.pop(context, p)),
          // Matches the laser against the new floor's map; the result is shown to check before it is set.
          if (scanTopic != null) ListTile(key: const Key('where-find'), contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.travel_explore), title: Text(context.strings.findAutomatically),
            subtitle: Text(context.strings.findAutoHint),
            onTap: () => Navigator.pop(context, 'find')),
          ListTile(key: const Key('where-on-map'), contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.my_location), title: Text(context.strings.showOnMap),
            onTap: () => Navigator.pop(context, 'map')),
        ]))));
    if (!mounted) return;
    if (chosen is Place) {
      _setInitialPose(chosen.pose);
    } else if (chosen == 'map' || chosen == 'find') {
      setState(() { tool = MapTool.setPose; pendingPose = robotPose; guess = null; searchProblem = null; });
      // Where the robot was on the old floor says nothing about this one: search the whole map.
      if (chosen == 'find') await findPosition(anywhere: true);
    }
  }

  Future<void> showPlaces() async {
    final chosen = await showModalBottomSheet<Place>(context: context, showDragHandle: true,
      builder: (context) => ListenableBuilder(listenable: placeBook, builder: (context, _) {
        final places = placeBook.usable;
        final floor = placeBook.floor;
        return SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(context.strings.places, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18))),
              // A building's floors each have their own map: name this one to keep its places apart.
              if (placeBook.currentMap != null) ActionChip(key: const Key('floor-name'),
                avatar: const Icon(Icons.layers_outlined, size: 18),
                label: Text(floor ?? context.strings.nameThisFloor), onPressed: () {
                  Navigator.pop(context); // one sheet at a time
                  showFloors();
                }),
            ]),
            if (placeBook.elsewhere > 0) Text('${placeBook.elsewhere} more on other floors',
              key: const Key('places-elsewhere'), style: TextStyle(color: context.muted)),
            const SizedBox(height: 4),
            Text(places.isEmpty
                ? context.strings.noPlacesYet
                : context.strings.tapPlacePreview,
              style: TextStyle(color: context.muted)),
            const SizedBox(height: 8),
            for (final place in places) ListTile(
              key: Key('place-${place.name}'),
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.place_outlined, color: Color(0xFF6A1B9A)),
              title: Text(place.name),
              subtitle: Text('x ${place.x.toStringAsFixed(2)} · y ${place.y.toStringAsFixed(2)}'),
              onTap: () => Navigator.pop(context, place),
              trailing: IconButton(tooltip: context.strings.deleteNamed(place.name), icon: const Icon(Icons.delete_outline),
                onPressed: () => placeBook.remove(place.name)),
            ),
          ])));
      }));
    if (chosen == null || !mounted) return;
    _place(chosen.pose);
  }

  /// Robot pose in the map frame: the full TF chain if available, else odometry composed with map->odom.
  Pose2D? get robotPose {
    // The odometry message names the base frame; without usable odometry try the usual names.
    for (final base in [if (baseFrame.isNotEmpty) baseFrame, 'base_footprint', 'base_link']) {
      if (!tf.has(base)) continue;
      final viaTf = tf.lookup(mapFrame, base);
      if (viaTf != null) return viaTf;
    }
    final odom = odomPose;
    if (odom == null) return null;
    if (TfTree.clean(odomFrame) == TfTree.clean(mapFrame)) return odom;
    final mapToOdom = tf.lookup(mapFrame, odomFrame);
    return mapToOdom?.compose(odom);
  }

  Future<void> connect() async {
    try {
      final client = widget.connectionFactory(widget.ip, widget.port);
      connection = client;
      final controller = nav = widget.nav ?? NavigationController(_ros = RosClient(client));
      controller.addListener(_onNav);
      patrol = PatrolController(_ros ??= RosClient(client))..addListener(() { if (mounted) setState(() {}); });
      if (controller.status != NavStatus.idle) {
        goal = controller.goal; // a goal sent earlier (by this page or the agent) is still shown
        _onNav();
      }
      client.messages.listen(_onMessage, onDone: () {
        if (mounted) setState(() => errorMessage = client.lastError ?? context.strings.robotDisconnectedShort);
      });
      await client.ready;
      if (!mounted) return;
      final caps = await (widget.capabilities?.call() ?? RobotCapabilities.discover(client));
      _nodes = caps.nodes;
      unawaited(_findNavTools(client));
      // A robot running SLAM is making its map: open there (only with a stick to drive it).
      if (!limitedRemote && (mapping || (widget.drive != null && mapperIn(caps.nodes) != null))) {
        mapping = true;
        _startMapping(client, caps.nodes);
      }
      final topics = caps.topics;
      final actions = caps.actionServers;
      if (!mounted || client.isClosed) return;
      final version = caps.rosVersion;
      final names = (topics?['topics'] as List?)?.map((t) => '$t').toList() ?? const <String>[];
      final types = (topics?['types'] as List?)?.map((t) => '$t'.replaceFirst('/msg/', '/')).toList() ?? const <String>[];
      // Pick by type, preferring conventional names, and skip topics nobody publishes (or listens) on.
      Future<String?> pick(String type, String name, {TopicRole role = TopicRole.read}) =>
          caps.pick(type, name, role: role);
      final namesToTypes = {for (var i = 0; i < names.length && i < types.length; i++) names[i]: types[i]};
      for (final k in CostmapKind.values) {
        costmapTopics[k] = costmapTopicIn(namesToTypes, k, namespace: widget.namespace);
      }
      final auto = <MapSlot, String?>{
        MapSlot.map: await pick('nav_msgs/OccupancyGrid', 'map'),
        MapSlot.odom: await pick('nav_msgs/Odometry', 'odom'),
        MapSlot.tf: await pick('tf2_msgs/TFMessage', 'tf'),
        MapSlot.tfStatic: rankByName(topicsOfType(topics, 'tf2_msgs/TFMessage'), 'tf_static')
            .where((t) => t.endsWith('tf_static')).firstOrNull,
        MapSlot.scan: await pick('sensor_msgs/LaserScan', 'scan'),
        MapSlot.plan: await pick('nav_msgs/Path', 'plan') ??
            [for (var i = 0; i < names.length && i < types.length; i++)
              if (types[i] == 'nav_msgs/Path' && names[i].toLowerCase().contains('plan') && !names[i].contains('local'))
                names[i]].firstOrNull,
        MapSlot.navAction: version == RosVersion.ros1 ? null
            : actions.where((a) => a == navigateToPoseAction || a.endsWith('/navigate_to_pose')).firstOrNull,
        // Only a topic called goal_pose; another PoseStamped listener is not a navigation goal
        // (MAVROS's position setpoint would fly a drone there).
        MapSlot.goal: switch (await pick('geometry_msgs/PoseStamped', 'goal_pose', role: TopicRole.write)) {
          final t? when t.endsWith('/goal_pose') => t,
          _ => null,
        },
        MapSlot.initialPose: await pick('geometry_msgs/PoseWithCovarianceStamped', 'initialpose', role: TopicRole.write),
      };
      final moveBase = actions.where((name) => name == '/move_base' || name.endsWith('/move_base')).firstOrNull;
      _moveBaseAction = moveBase;
      final overrides = await MapTopicStore.loadAt(widget.savedAs);
      if (!mounted || client.isClosed) return;
      _topicsInfo = topics;
      _actionNames = actions;
      patrol?.configure(actions, namespace: widget.namespace);
      automaticTopics = auto;
      topicOverrides = overrides;
      _discovered = true;
      rosVersion = version;
      _applyTopics();
    } catch (e) {
      if (mounted) setState(() => errorMessage = context.strings.connectionFailed('$e'));
    }
  }

  /// The topic in use for [slot]: the manual override, else what discovery found.
  String? topicFor(MapSlot slot) => topicOverrides[slot] ?? automaticTopics[slot];

  /// Brings subscriptions and advertisements in line with the current topic choice, so a change in the
  /// topic settings takes effect without reconnecting.
  void _applyTopics() {
    _watchMapArrival();
    final client = connection, version = rosVersion;
    if (client == null || client.isClosed || version == null) return;
    final oldMap = mapTopic, oldOdom = odomTopic, oldScan = scanTopic, oldPlan = planTopic;
    final ns = widget.namespace;
    mapTopic = topicFor(MapSlot.map) ?? '$ns/map';
    odomTopic = topicFor(MapSlot.odom) ?? '$ns/odom';
    tfTopic = topicFor(MapSlot.tf) ?? '$ns/tf';
    tfStaticTopic = topicFor(MapSlot.tfStatic) ?? '$ns/tf_static';
    scanTopic = topicFor(MapSlot.scan);
    planTopic = topicFor(MapSlot.plan);
    _initialPoseTopic = topicFor(MapSlot.initialPose) ?? '$ns$initialPoseTopic';
    nav?.configure(version: version, navigateAction: topicFor(MapSlot.navAction),
        goalTopic: topicFor(MapSlot.goal), moveBaseAction: _moveBaseAction);

    // Subscriptions: no throttle on TF (it mixes fast odom->base with slower map->odom from AMCL).
    final wantSubs = <String, int?>{
      mapTopic: 500, odomTopic: 100, tfTopic: null, tfStaticTopic: null,
      ?scanTopic: 200,
      ?planTopic: 500,
      for (final k in CostmapKind.values)
        if (showCostmap[k] == true && costmapTopics[k] != null) costmapTopics[k]!: 1000,
    };
    for (final t in _subscribed.difference(wantSubs.keys.toSet())) {
      try { client.send({'op': 'unsubscribe', 'topic': t}); } catch (_) {}
    }
    for (final e in wantSubs.entries) {
      if (_subscribed.contains(e.key)) continue;
      client.send({'op': 'subscribe', 'topic': e.key, if (e.value != null) 'throttle_rate': e.value});
    }
    _subscribed = wantSubs.keys.toSet();

    // Goal and cancel topics belong to the navigation controller.
    final wantAds = <String, String>{
      if (!limitedRemote) _initialPoseTopic: initialPoseType(version),
    };
    for (final t in _advertised.keys.where((t) => wantAds[t] != _advertised[t]).toList()) {
      try { client.send({'op': 'unadvertise', 'topic': t}); } catch (_) {}
      _advertised.remove(t);
    }
    for (final e in wantAds.entries) {
      if (_advertised.containsKey(e.key)) continue;
      client.send({'op': 'advertise', 'topic': e.key, 'type': e.value});
      _advertised[e.key] = e.value;
    }

    setState(() {
      if (oldMap != mapTopic) { mapData = []; mapWidth = 0; mapHeight = 0; _fitted = false; }
      if (oldOdom != odomTopic) { odomPose = null; baseFrame = ''; }
      if (oldScan != scanTopic) scanPoints = [];
      if (oldPlan != planTopic) path = [];
    });
  }

  Future<void> openTopicSettings() async {
    if (rosVersion == null) return;
    final result = await showMapTopicSheet(context, overrides: topicOverrides, automatic: automaticTopics,
        topics: _topicsInfo, actions: _actionNames);
    if (result == null || !mounted) return;
    if (navState == NavState.active) cancelGoal();
    topicOverrides = result;
    _applyTopics();
    try {
      await MapTopicStore.saveAt(widget.savedAs, result);
    } catch (e) {
      if (mounted) setState(() => errorMessage = context.strings.topicSaveFailed('$e'));
    }
  }

  void _onMessage(Map<String, dynamic> event) {
    if (!mounted) return;
    try {
      final op = event['op'];
      if (op == 'action_feedback' || op == 'action_result') return; // followed by the navigation controller
      final refused = statusErrorIn(event, context.strings);
      if (refused != null) throw StateError(refused);
      final msg = event['msg'];
      if (msg is! Map) return;
      final topic = event['topic'];
      if (topic == mapTopic) {
        _onMap(msg);
      } else if (costmapTopics.containsValue(topic)) {
        _onCostmap(costmapTopics.entries.firstWhere((e) => e.value == topic).key, msg);
      } else if (topic == odomTopic) {
        final p = msg['pose']['pose'];
        odomPose = Pose2D((p['position']['x'] as num).toDouble(), (p['position']['y'] as num).toDouble(),
            p['orientation'] is Map ? yawOf(p['orientation'] as Map) : 0);
        odomFrame = TfTree.clean(msg['header']['frame_id'] as String);
        baseFrame = TfTree.clean('${msg['child_frame_id'] ?? ''}');
        rebuildSoon();
        nav?.updateRobotPose(robotPose);
      } else if (topic == tfTopic || topic == tfStaticTopic) {
        var changed = false;
        for (final t in msg['transforms'] as List) {
          changed = tf.add(t as Map) || changed;
        }
        if (changed) rebuildSoon();
      } else if (topic == planTopic) {
        final frame = TfTree.clean('${msg['header']?['frame_id'] ?? mapFrame}');
        final toMap = frame == mapFrame ? Pose2D.identity : tf.lookup(mapFrame, frame);
        if (toMap == null) return;
        path = [
          for (final p in msg['poses'] as List)
            toMap.apply((p['pose']['position']['x'] as num).toDouble(), (p['pose']['position']['y'] as num).toDouble()),
        ];
        rebuildSoon();
      } else if (topic == scanTopic) {
        final sensor = tf.lookup(mapFrame, msg['header']['frame_id'] as String);
        if (sensor == null) return;
        final min = (msg['angle_min'] as num).toDouble(), inc = (msg['angle_increment'] as num).toDouble();
        final rMin = (msg['range_min'] as num).toDouble(), rMax = (msg['range_max'] as num).toDouble();
        final ranges = msg['ranges'] as List;
        final points = <math.Point<double>>[];
        for (var i = 0; i < ranges.length; i++) {
          final r = ranges[i];
          if (r is! num || !r.isFinite || r < rMin || r > rMax) continue; // null/inf from rosbridge = no return
          final a = min + i * inc;
          points.add(sensor.apply(r * math.cos(a), r * math.sin(a)));
        }
        scanPoints = points;
        final r = robotPose;
        if (r != null) {
          final c = math.cos(-r.yaw), s = math.sin(-r.yaw);
          scanLocal = [
            for (final p in points) math.Point((p.x - r.x) * c - (p.y - r.y) * s, (p.x - r.x) * s + (p.y - r.y) * c),
          ];
        }
        rebuildSoon();
      }
    } catch (e) {
      if (mounted) setState(() => errorMessage = context.strings.mapDataError('$e'));
    }
  }

  void _onCostmap(CostmapKind kind, Map msg) {
    if (showCostmap[kind] != true) return;
    final costmap = Costmap.fromMessage(msg);
    if (costmap == null) {
      // Too large to draw (a big global costmap arrives as JSON every second): stop asking for it.
      final cells = ((msg['info'] as Map?)?['width'] as int? ?? 0) * ((msg['info'] as Map?)?['height'] as int? ?? 0);
      if (cells > Costmap.maxCells) {
        _costmapTooLarge.add(kind);
        showCostmap[kind] = false;
        _applyTopics();
      }
      return;
    }
    _costmaps[kind] = costmap;
    ui.decodeImageFromPixels(costmap.rgba(), costmap.width, costmap.height, ui.PixelFormat.rgba8888, (image) {
      if (!mounted || _costmaps[kind] != costmap) { image.dispose(); return; }
      final previous = _costmapImages[kind];
      setState(() => _costmapImages[kind] = image);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    });
  }

  /// The costmaps ready to draw, each placed in the map frame by the current TF.
  List<CostmapOverlay> _costmapOverlays() {
    final out = <CostmapOverlay>[];
    for (final kind in [CostmapKind.global, CostmapKind.local]) { // local on top
      final map = _costmaps[kind], image = _costmapImages[kind];
      if (showCostmap[kind] != true || map == null || image == null) continue;
      final frame = TfTree.clean(map.frame);
      final toMap = frame.isEmpty || frame == mapFrame ? Pose2D.identity : tf.lookup(mapFrame, frame);
      if (toMap == null) continue;
      out.add(CostmapOverlay(image: image, width: map.width, height: map.height, resolution: map.resolution,
          origin: map.origin, toMap: toMap));
    }
    return out;
  }

  void _toggleCostmap(CostmapKind kind) {
    final on = !(showCostmap[kind] ?? false);
    setState(() {
      showCostmap[kind] = on;
      if (!on) {
        _costmaps[kind] = null;
        _costmapImages.remove(kind)?.dispose();
      }
    });
    _applyTopics();
  }

  void _onMap(Map msg) {
    final info = msg['info'] as Map;
    final width = info['width'] as int, height = info['height'] as int;
    final cells = List<int>.from(msg['data'] as List);
    final scale = (info['resolution'] as num).toDouble();
    if (width <= 0 || height <= 0 || scale <= 0 || !scale.isFinite || cells.length != width * height) {
      throw const FormatException('Invalid occupancy grid');
    }
    final o = info['origin'];
    _renderMapImage(cells, width, height);
    final sizeChanged = width != mapWidth || height != mapHeight;
    setState(() {
      mapWidth = width; mapHeight = height; mapData = cells; resolution = scale;
      origin = Pose2D((o['position']['x'] as num).toDouble(), (o['position']['y'] as num).toDouble(),
          yawOf(o['orientation'] as Map));
      mapFrame = TfTree.clean(msg['header']['frame_id'] as String);
      knownCells = knownArea(cells, width, height, scale);
      if (sizeChanged) _fitted = false;
    });
    placeBook.observeMap(mapping ? null : PlaceBook.mapKey(frame: mapFrame, width: width, height: height,
        resolution: scale, originX: origin.x, originY: origin.y));
    WidgetsBinding.instance.addPostFrameCallback((_) { if (!_fitted) fitToMap(); });
  }

  /// Colours the grid was last rasterised with; a light/dark switch re-rasterises it.
  MapPalette _palette = MapPalette.light;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final palette = MapPalette.of(context);
    if (palette != _palette) {
      _palette = palette;
      if (mapData.isNotEmpty) _renderMapImage(mapData, mapWidth, mapHeight);
    }
  }

  /// Rasterises the occupancy grid once per /map message; painting then blits one image.
  void _renderMapImage(List<int> cells, int width, int height) {
    final generation = ++_mapImageGeneration;
    final pixels = Uint8List(width * height * 4);
    final lut = _palette.rgbaTable();
    for (var row = 0; row < height; row++) {
      final screenRow = height - 1 - row; // ROS row 0 is the bottom of the map
      var i = screenRow * width * 4;
      var cell = row * width;
      for (var col = 0; col < width; col++, cell++, i += 4) {
        final v = cells[cell];
        // Occupancy is -1 (unknown) or 0..100; anything else shares the "uncertain" colour.
        final k = (v < -1 || v > 100 ? 50 : v + 1) * 4;
        pixels[i] = lut[k];
        pixels[i + 1] = lut[k + 1];
        pixels[i + 2] = lut[k + 2];
        pixels[i + 3] = lut[k + 3];
      }
    }
    ui.decodeImageFromPixels(pixels, width, height, ui.PixelFormat.rgba8888, (image) {
      if (!mounted || generation != _mapImageGeneration) { image.dispose(); return; }
      final previous = mapImage;
      setState(() => mapImage = image);
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    });
  }

  // ---- view -----------------------------------------------------------------------------

  Size get canvasSize => Size(mapWidth * cellPx, mapHeight * cellPx);

  Offset toCanvas(double x, double y) {
    final p = worldToScreen(x, y, canvasSize.width, canvasSize.height, mapWidth, mapHeight, resolution,
        origin.x, origin.y, origin.yaw);
    return Offset(p.x, p.y);
  }

  math.Point<double> toWorld(Offset canvas) => screenToWorld(canvas.dx, canvas.dy, canvasSize.width,
      canvasSize.height, mapWidth, mapHeight, resolution, origin.x, origin.y, origin.yaw);

  /// Frames the explored area (or the whole map) in the viewport.
  void fitToMap() {
    if (mapWidth == 0 || _viewport.isEmpty) return;
    final r = Rect.fromLTWH(knownCells.left * cellPx, (mapHeight - knownCells.bottom) * cellPx,
        knownCells.width * cellPx, knownCells.height * cellPx);
    _frame(r.center, math.min(_viewport.width / r.width, _viewport.height / r.height) * 0.92);
    _fitted = true;
  }

  void centerOnRobot() {
    final robot = robotPose;
    if (robot == null) return;
    _frame(toCanvas(robot.x, robot.y), viewer.value.getMaxScaleOnAxis());
  }

  void _frame(Offset canvasPoint, double scale) {
    final s = scale.clamp(0.05, 20.0);
    viewer.value = Matrix4.identity()
      ..translateByDouble(_viewport.width / 2 - canvasPoint.dx * s, _viewport.height / 2 - canvasPoint.dy * s, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  // ---- goals ----------------------------------------------------------------------------

  void _onTap(Offset canvas) {
    final w = toWorld(canvas);
    _selectWorld(Offset(w.x, w.y));
  }

  void _selectWorld(Offset w) {
    final robot = robotPose;
    if (tool == MapTool.setPose) {
      // Where the robot really is; it keeps the heading it believes it has until the person turns it.
      setState(() => pendingPose = Pose2D(w.dx, w.dy, pendingPose?.yaw ?? robot?.yaw ?? 0));
      return;
    }
    // Without a drawn heading, face the direction of travel.
    final yaw = robot == null ? 0.0 : math.atan2(w.dy - robot.y, w.dx - robot.x);
    _place(Pose2D(w.dx, w.dy, yaw));
  }

  /// Both views select the same map-frame destination and require an explicit Go.
  late bool view3d = widget.initial3d;
  final _map3dKey = GlobalKey<Map3DViewState>();

  /// The robot position being chosen in Set pose mode, sent only when confirmed.
  Pose2D? pendingPose;

  // ---- making a map ----------------------------------------------------------------------

  /// "Make a map" mode (see [MapVisualizationPage.mapping]).
  late bool mapping = widget.mapping;
  List<String> _nodes = const [];

  /// Switches between navigating and making a map.
  void setMapping(bool on) {
    if (on == mapping) return;
    setState(() {
      mapping = on;
      tool = MapTool.goal;
      pendingPose = null;
      guess = null;
      searchProblem = null;
    });
    final client = connection;
    if (on) {
      if (client != null && !client.isClosed) _startMapping(client, _nodes);
    } else {
      _releaseStick();
    }
  }

  void _releaseStick() {
    final drive = widget.drive;
    _stick = Offset.zero;
    if (drive != null && drive.manualInput == _stickCommand) {
      drive.manualInput = () => DriveCommand.stop;
      drive.stop();
    }
  }

  /// What the robot runs for mapping (null while checking).
  MappingSetup? mappingSetup;
  bool savingMap = false;
  String? mapSaveNote;
  bool mapSaveFailed = false;
  Offset _stick = Offset.zero;

  Future<void> _startMapping(RosConnection client, List<String> nodes) async {
    final setup = await detectMapping(client, nodes, namespace: widget.namespace);
    if (!mounted || !mapping) return;
    setState(() => mappingSetup = setup);
    final drive = widget.drive;
    if (drive == null) return;
    try {
      await widget.prepare?.call();
    } catch (_) {}
    if (!mounted || !mapping) return;
    drive.manualInput = _stickCommand;
    setState(() {});
  }

  Future<void> recheckMapping() async {
    final client = connection;
    if (client == null || client.isClosed) return;
    setState(() => mappingSetup = null);
    final caps = await RobotCapabilities.discover(client);
    _nodes = caps.nodes;
    if (mounted) await _startMapping(client, caps.nodes);
  }

  /// The stick drives at the Normal preset (Slow is too slow for SLAM to take new scans: it adds one
  /// only after ~0.5 m or ~30°), through the session's drive controller.
  DriveCommand _stickCommand() {
    final profile = widget.drive?.profile;
    if (profile == null || _stick == Offset.zero) return DriveCommand.stop;
    return commandFor(profile, SpeedPreset.normal, StickInput(leftY: _stick.dy, rightX: _stick.dx));
  }

  bool get _canDrive {
    final p = widget.drive?.profile;
    return p != null && p.hasBase && p.drive != DriveType.aerial;
  }

  Future<void> saveMap() async {
    if (savingMap || mapData.isEmpty) return;
    final setup = mappingSetup;
    final name = await showDialog<String>(context: context,
        builder: (_) => _SaveMapDialog(onRobot: setup?.canSaveOnRobot == true));
    if (name == null || !mounted) return;
    setState(() { savingMap = true; mapSaveNote = null; mapSaveFailed = false; });
    final done = <String>[], problems = <String>[];
    if (setup != null && setup.canSaveOnRobot) {
      try {
        await saveMapOnRobot(_ros ??= RosClient(connection!), setup, name, mapTopic: mapTopic);
        done.add('on the robot');
        _savedOnRobot = '$name.yaml';
      } catch (e) {
        problems.add(e is StateError ? e.message : 'Robot: $e');
      }
    }
    try {
      final base = await (widget.mapFolder?.call() ??
          getApplicationDocumentsDirectory().then((d) => Directory('${d.path}/maps')));
      await saveMapOnPhone(base, name, mapData, mapWidth, mapHeight, resolution, origin);
      done.add('on this phone');
    } catch (e) {
      if (mounted) problems.add(context.strings.phoneCopyFailed('$e'));
    }
    if (!mounted) return;
    setState(() {
      savingMap = false;
      mapSaveFailed = done.isEmpty;
      mapSaveNote = [
        if (done.isNotEmpty) done.length == 2 ? context.strings.mapSavedBoth(name)
            : done.single == 'on the robot' ? context.strings.mapSavedOnRobot(name) : context.strings.mapSavedOnPhone(name),
        ...problems,
      ].join(' ');
    });
  }

  void _mappingTips() => showModalBottomSheet<void>(context: context, showDragHandle: true,
    builder: (context) => SafeArea(child: Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(context.strings.makingGoodMap, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        for (final tip in [
          context.strings.mapTip1,
          if (nav?.configured == true) context.strings.mapTip2,
          context.strings.mapTip3,
          context.strings.mapTip4,
        ]) Padding(padding: const EdgeInsets.only(bottom: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start,
          children: [const Text('•  '), Expanded(child: Text(tip))])),
      ]))));

  Widget _mappingCard(TextStyle title, TextStyle sub) {
    final setup = mappingSetup, cs = Theme.of(context).colorScheme;
    final area = mappedArea(mapData, resolution);
    final drives = _canDrive;
    // One line; the details are behind the (?) when someone wants them.
    final hint = drives ? context.strings.mapHintDrive : context.strings.mapHintAround;
    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Icon(setup?.mapping == false ? Icons.warning_amber_rounded : Icons.radar, size: 18,
          color: setup?.mapping == false ? const Color(0xFFB26A00) : cs.primary),
        const SizedBox(width: 6),
        Expanded(child: Text(setup == null ? context.strings.checkingMapping
            : setup.mapping ? context.strings.makingMap : context.strings.notMapping, style: title)),
      ]),
      const SizedBox(height: 2),
      Text('${area.toStringAsFixed(area < 10 ? 1 : 0)} m² mapped${setup?.mapper == null ? '' : ' · ${setup!.mapper}'}',
        key: const Key('map-area'), style: sub.copyWith(fontWeight: FontWeight.w600, color: context.ink)),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(child: Text(setup?.mapping == false ? 'SLAM is not running: the map will not grow.' : hint,
          style: sub)),
        IconButton(key: const Key('mapping-tips'), tooltip: context.strings.tips, visualDensity: VisualDensity.compact,
          icon: Icon(Icons.help_outline, size: 18, color: context.muted), onPressed: _mappingTips),
      ]),
      if (mapSaveNote != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text(mapSaveNote!,
        key: const Key('map-save-note'),
        style: sub.copyWith(color: mapSaveFailed ? cs.error : const Color(0xFF2E7D32), fontWeight: FontWeight.w600))),
      const SizedBox(height: 8),
      Align(alignment: Alignment.centerRight, child: FilledButton.icon(key: const Key('save-map'),
        onPressed: savingMap ? null : saveMap,
        icon: savingMap
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.save_alt, size: 18),
        label: Text(savingMap ? context.strings.saving : context.strings.saveMap))),
    ]);
    if (!drives) return info;
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      ControlStick(key: const Key('mapping-stick'), size: 116, onChanged: (o) {
        _stick = o;
        widget.drive?.tick();
      }),
      const SizedBox(width: 14),
      Expanded(child: info),
    ]);
  }

  Widget _mappingHelp() {
    final cs = Theme.of(context).colorScheme;
    return Container(color: context.page, child: SafeArea(child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 140, 20, 16),
      child: Center(child: SingleChildScrollView(child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.radar, size: 40, color: cs.primary),
          const SizedBox(height: 12),
          Text(context.strings.startMappingTitle, key: const Key('mapping-help-title'),
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: context.ink)),
          const SizedBox(height: 6),
          Text(context.strings.startMappingHelp, style: TextStyle(color: context.muted)),
          const SizedBox(height: 12),
          for (final (label, command) in mappingStartHelp) Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(color: context.card, borderRadius: BorderRadius.circular(12),
              child: ListTile(
                title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(command, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                trailing: IconButton(tooltip: context.strings.copy, icon: const Icon(Icons.copy, size: 18),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: command));
                    if (mounted) {
                      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.copied)));
                    }
                  })))),
          const SizedBox(height: 8),
          FilledButton.icon(key: const Key('mapping-recheck'), onPressed: recheckMapping,
            icon: const Icon(Icons.refresh, size: 18), label: Text(context.strings.checkAgain)),
        ]))))))) ;
  }

  /// The latest laser scan in the robot's base frame (for matching it against the map anywhere).
  List<math.Point<double>> scanLocal = [];

  /// "Find automatically": searching, and what it found (shown while [pendingPose] is still that spot).
  bool searching = false;
  PoseGuess? guess;
  String? searchProblem;

  /// The laser drawn as if the robot stood at [pendingPose], so the person sees whether it fits.
  List<math.Point<double>> get previewScan {
    final p = pendingPose;
    if (p == null || tool != MapTool.setPose) return const [];
    return [for (final q in scanLocal) p.apply(q.x, q.y)];
  }

  /// How much of the laser lies on the map's walls if the robot stood at [pendingPose].
  double? get previewMatch => scanMatch(previewScan, mapData, mapWidth, mapHeight, resolution, origin);

  /// Matches the current laser scan against the whole map (on the phone; the robot does not move) and
  /// puts the best spot into the Set pose preview, for the person to check and confirm.
  Future<void> findPosition({bool anywhere = false}) async {
    if (searching) return;
    if (scanLocal.length < 10 || mapData.isEmpty) {
      setState(() => searchProblem = scanTopic == null
          ? context.strings.noLaserRobot
          : context.strings.noLaserYet);
      return;
    }
    setState(() { searching = true; searchProblem = null; guess = null; });
    final query = PoseSearch(cells: List<int>.of(mapData), width: mapWidth, height: mapHeight,
        resolution: resolution, origin: origin, scan: List.of(scanLocal), prior: anywhere ? null : robotPose);
    PoseGuess? found;
    try {
      found = await compute(findPose, query);
    } catch (e) {
      if (mounted) searchProblem = context.strings.searchFailed('$e');
    }
    if (!mounted) return;
    setState(() {
      searching = false;
      if (found == null) {
        searchProblem ??= context.strings.cannotSearch;
      } else {
        guess = found;
        pendingPose = found.pose;
      }
    });
  }

  void _place(Pose2D pose) {
    if (tool == MapTool.setPose) {
      setState(() => pendingPose = pose); // a drawn pose is previewed and confirmed like a tapped one
      return;
    }
    if (navState == NavState.active) return; // cancel first
    nav?.reset();
    final problem = _goalProblem(pose);
    setState(() {
      errorMessage = problem;
      goal = problem == null ? pose : null;
      navState = problem == null ? NavState.preview : NavState.idle;
    });
  }

  String? _goalProblem(Pose2D pose) {
    if (!pose.x.isFinite || !pose.y.isFinite || !pose.yaw.isFinite) return context.strings.chooseValidPosition;
    if (mapData.isEmpty) return null;
    return switch (mapCellAt(pose.x, pose.y, cells: mapData, width: mapWidth, height: mapHeight,
        resolution: resolution, origin: origin)) {
      MapCellState.outside => context.strings.outsideMap,
      MapCellState.occupied => context.strings.onObstacle,
      _ => null,
    };
  }

  void _setInitialPose(Pose2D pose) {
    final version = rosVersion;
    if (version == null || connection == null) return;
    try {
      connection!.send({'op': 'publish', 'topic': _initialPoseTopic,
        'msg': initialPoseMessage(version, mapFrame, pose.x, pose.y, pose.yaw)});
      setState(() { tool = MapTool.goal; pendingPose = null; });
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(context.strings.positionSet)));
    } catch (e) {
      setState(() => errorMessage = context.strings.setPositionFailed('$e'));
    }
  }

  void sendGoal() {
    final g = goal, controller = nav, client = connection;
    if (g == null || rosVersion == null || controller == null || client == null || client.isClosed) return;
    final problem = _goalProblem(g);
    if (problem != null) {
      setState(() { errorMessage = problem; goal = null; navState = NavState.idle; });
      return;
    }
    try {
      patrol?.cancel(); // a trip of its own ends a round: one thing at a time
      controller.goTo(g, frame: mapFrame, from: robotPose);
      setState(() => errorMessage = null);
    } catch (e) {
      setState(() => errorMessage = context.strings.sendGoalFailed('$e'));
    }
  }

  void cancelGoal() => nav?.cancel();

  /// Mirrors the controller: a running or finished goal replaces the page's own idle/preview state.
  void _onNav() {
    if (!mounted) return;
    final status = nav!.status;
    setState(() {
      switch (status) {
        case NavStatus.idle:
          break; // idle and preview are the page's to decide
        case NavStatus.active:
          navState = NavState.active;
        case NavStatus.succeeded:
          navState = NavState.succeeded;
          path = [];
        case NavStatus.canceled:
          navState = NavState.canceled;
          path = [];
        case NavStatus.failed:
          navState = NavState.failed;
          path = [];
      }
    });
  }

  @override
  void dispose() {
    for (final image in _costmapImages.values) { image?.dispose(); }
    _releaseStick();
    _mapSlowTimer?.cancel();
    placeBook.removeListener(_onPlaces);
    if (widget.places == null) placeBook.dispose();
    ++_mapImageGeneration;
    mapImage?.dispose();
    viewer.dispose();
    for (final t in _advertised.keys) {
      try { connection?.send({'op': 'unadvertise', 'topic': t}); } catch (_) {}
    }
    nav?.removeListener(_onNav);
    if (patrol?.isRunning == true) patrol!.cancel(); // leaving the screen does not leave a round running unseen
    patrol?.dispose();
    if (widget.nav == null) {
      nav?.dispose(); // withdraws its goal topics; a running goal keeps going on the robot
      _ros?.dispose();
    }
    connection?.close();
    super.dispose();
  }

  // ---- UI -------------------------------------------------------------------------------

  String get navLabel => nav?.label ?? 'Nav2 · /goal_pose';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MapPalette.of(context).background,
      body: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 1000 && box.maxHeight >= 600) {
          final side = MediaQuery.textScalerOf(context).scale(14) > 20 ? 420.0 : 360.0;
          return SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
            _topBar(),
            if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: _banner(errorMessage!)),
            const SizedBox(height: 12),
            Expanded(child: Row(key: const Key('navigation-panes'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(18), child: _mapViewport())),
              const SizedBox(width: 12),
              SizedBox(width: side, child: _navigationPanel()),
            ])),
          ])));
        }
        return Stack(children: [
        Positioned.fill(child: _mapViewport()),
        SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
          _topBar(),
          if (errorMessage != null) Padding(padding: const EdgeInsets.only(top: 8), child: _banner(errorMessage!)),
          const Spacer(),
          if (mapData.isNotEmpty) ConstrainedBox(
            constraints: BoxConstraints(maxHeight: box.maxHeight * 0.45),
            child: SingleChildScrollView(child: Align(alignment: Alignment.bottomCenter, child: _statusCard())),
          ),
        ]))),
      ]);
      }),
    );
  }

  Widget _mapViewport() => Stack(children: [
        Positioned.fill(child: LayoutBuilder(builder: (context, box) {
          final viewport = Size(box.maxWidth, box.maxHeight);
          if (viewport != _viewport) {
            // An empty viewer still has an identity transform. Preserving that "centre" while the
            // first grid arrives would pan the real map off screen after a rotation/resize.
            final preserve = _fitted && mapData.isNotEmpty && !_viewport.isEmpty;
            final center = !preserve ? null : viewer.toScene(Offset(_viewport.width / 2, _viewport.height / 2));
            final scale = viewer.value.getMaxScaleOnAxis();
            _viewport = viewport;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              if (!_fitted || !preserve) { fitToMap(); } else if (center != null && !view3d) { _frame(center, scale); }
            });
          }
          if (mapData.isEmpty && mapping && mappingSetup?.mapping == false) return _mappingHelp();
          if (mapData.isEmpty) return _waiting();
          return view3d ? KeyedSubtree(key: const Key('map-3d'), child: Map3DView(key: _map3dKey,
              image: mapImage, cells: mapData, width: mapWidth,
              height: mapHeight, resolution: resolution, origin: origin, robot: robotPose,
              goal: tool == MapTool.setPose ? pendingPose : goal,
              scan: showScan ? scanPoints : const [], path: showPath ? path : const [],
              onGroundTap: _selectWorld,
              places: [for (final p in placeBook.usable) if (p.frame == mapFrame) (p.name, p.pose)],
              wallColor: _palette.wall, background: _palette.background)) : _canvas();
        })),
        if (mapData.isNotEmpty && !view3d) Positioned(right: 12, top: 140, child: _viewButtons()),
      ]);

  Widget _navigationPanel() => Material(color: context.page, borderRadius: BorderRadius.circular(18),
    child: SingleChildScrollView(padding: const EdgeInsets.all(12), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(context.strings.navigation, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        _statusCard(),
        const SizedBox(height: 24),
        Text(context.strings.savedPlaces, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (placeBook.usable.isEmpty) Text(context.strings.saveDestinationHint, style: TextStyle(color: context.muted)),
        for (final place in placeBook.usable) ListTile(
          contentPadding: EdgeInsets.zero, leading: const Icon(Icons.bookmark_outline),
          title: Text(place.name), subtitle: Text('X ${place.x.toStringAsFixed(2)} · Y ${place.y.toStringAsFixed(2)} m'),
          enabled: navState != NavState.active && place.frame == mapFrame,
          trailing: const Icon(Icons.chevron_right), onTap: () => _place(place.pose)),
      ])));

  /// After the topics are chosen, gives the map a few seconds before saying it is not coming.
  void _watchMapArrival() {
    _mapSlowTimer?.cancel();
    mapSlow = false;
    _mapSlowTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && mapData.isEmpty) setState(() => mapSlow = true);
    });
  }

  /// What the map area shows before there is a map: looking, none on this robot, or none arriving.
  Widget _waiting() {
    final noTopic = _discovered && topicFor(MapSlot.map) == null;
    final (title, detail) = !_discovered
        ? (context.strings.mapLooking, null)
        : noTopic
            ? (context.strings.robotNoMap, context.strings.noMapDetail)
            : mapSlow
                ? (context.strings.mapMissing(mapTopic), context.strings.mapCheckSource)
                : (context.strings.mapWaiting, null);
    final stuck = noTopic || mapSlow;
    return Container(color: context.page, child: SafeArea(child: Padding(
      padding: const EdgeInsets.fromLTRB(24, 140, 24, 16),
      child: Center(child: SingleChildScrollView(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (stuck)
          Icon(Icons.map_outlined, size: 40, color: context.muted)
        else
          const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(title, key: const Key('map-waiting-title'), textAlign: TextAlign.center,
          style: const TextStyle(fontWeight: FontWeight.w700)),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(detail, textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
        ],
        if (noTopic && widget.drive != null) ...[
          const SizedBox(height: 16),
          FilledButton.icon(key: const Key('map-start-mapping'), onPressed: () => setMapping(true),
            icon: const Icon(Icons.radar, size: 18), label: Text(context.strings.makeMap)),
        ],
        if (stuck && rosVersion != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(key: const Key('choose-map-topic'), onPressed: openTopicSettings,
            icon: const Icon(Icons.tune, size: 18), label: Text(context.strings.chooseMapTopic)),
        ],
      ]),
    )))));
  }

  Widget _canvas() {
    final size = canvasSize;
    final robot = robotPose;
    return InteractiveViewer(
      transformationController: viewer,
      constrained: false,
      minScale: 0.05,
      maxScale: 20,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: GestureDetector(
        onTapUp: (d) => _onTap(d.localPosition),
        onLongPressStart: (d) => setState(() { _dragAnchor = d.localPosition; _dragYaw = null; }),
        onLongPressMoveUpdate: (d) {
          final a = _dragAnchor;
          if (a == null) return;
          final from = toWorld(a), to = toWorld(d.localPosition);
          if ((d.localPosition - a).distance > 6) setState(() => _dragYaw = math.atan2(to.y - from.y, to.x - from.x));
        },
        onLongPressEnd: (d) {
          final a = _dragAnchor;
          if (a == null) return;
          final w = toWorld(a);
          final yaw = _dragYaw;
          setState(() { _dragAnchor = null; _dragYaw = null; });
          if (yaw == null) { _onTap(a); } else { _place(Pose2D(w.x, w.y, yaw)); }
        },
        child: CustomPaint(key: _canvasKey, size: size, painter: MapPainter(
          image: mapImage, mapData: mapData, width: mapWidth, height: mapHeight, resolution: resolution,
          origin: origin, robot: robot, goal: goal, goalActive: navState == NavState.active,
          places: [for (final p in placeBook.usable) (p.name, p.pose)],
          path: showPath ? path : const [], scan: showScan ? scanPoints : const [],
          dragAnchor: _dragAnchor, dragYaw: _dragYaw, setPose: tool == MapTool.setPose,
          pendingPose: tool == MapTool.setPose ? pendingPose : null, palette: _palette, previewScan: previewScan,
          costmaps: _costmapOverlays(),
        )),
      ),
    );
  }

  String _costmapName(CostmapKind k) =>
      k == CostmapKind.local ? context.strings.localCostmap : context.strings.globalCostmap;

  Widget _glass({required Widget child, EdgeInsets padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(color: context.card.withValues(alpha: 0.97), borderRadius: BorderRadius.circular(22),
          border: Border.all(color: context.border),
          boxShadow: const [BoxShadow(color: Color(0x1A000000), blurRadius: 20, offset: Offset(0, 5))]),
        child: child,
      );

  /// Goal / Set pose / Make a map. Making a map needs the workspace's stick ([MapVisualizationPage.drive]).
  /// A segment name on one line, shrunk a little on narrow phones rather than broken ("Make / map").
  static Widget _oneLine(String text) => FittedBox(fit: BoxFit.scaleDown, child: Text(text, maxLines: 1, softWrap: false));

  Widget _toolToggle() => limitedRemote ? Padding(padding: const EdgeInsets.all(8), child: Text(context.strings.remoteNavigation)) : SegmentedButton<String>(
    key: const Key('map-tool'),
    style: SegmentedButton.styleFrom(visualDensity: VisualDensity.compact),
    showSelectedIcon: false,
    segments: [
      ButtonSegment(value: 'goal', icon: const Icon(Icons.flag_outlined, size: 18), label: _oneLine(context.strings.goal)),
      ButtonSegment(value: 'pose', icon: const Icon(Icons.my_location, size: 18), label: _oneLine(context.strings.setPose)),
      if (widget.drive != null || mapping)
        ButtonSegment(value: 'map', icon: const Icon(Icons.radar, size: 18), label: _oneLine(context.strings.makeMapShort)),
    ],
    selected: {mapping ? 'map' : tool == MapTool.setPose ? 'pose' : 'goal'},
    onSelectionChanged: (s) {
      final v = s.first;
      if (v == 'map') return setMapping(true);
      if (mapping) setMapping(false);
      // Set pose starts from where the robot thinks it is, so the person only corrects it.
      setState(() {
        tool = v == 'pose' ? MapTool.setPose : MapTool.goal;
        pendingPose = tool == MapTool.setPose ? robotPose : null;
        guess = null;
        searchProblem = null;
      });
    },
  );

  /// Back, title and layers; the Goal / Set pose toggle sits inline on wide screens, below on phones.
  Widget _topBar() => LayoutBuilder(builder: (context, box) {
    final largeText = MediaQuery.textScalerOf(context).scale(14) >= 20;
    final wide = box.maxWidth >= 640 && !largeText;
    final stackedTitle = box.maxWidth < 520 && largeText;
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min,
      children: [
        Text(mapping ? context.strings.makeMap : context.strings.mapNavigation,
          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        Text(rosVersion == null ? context.strings.detectingNav : [?placeBook.floor, navLabel].join(' · '), key: const Key('nav-target'),
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: context.muted, fontSize: 12)),
      ]);
    final layers = PopupMenuButton<String>(
      key: const Key('map-layers'),
      tooltip: context.strings.layers,
      icon: const Icon(Icons.layers_outlined),
      itemBuilder: (_) => [
        CheckedPopupMenuItem(value: 'path', checked: showPath, enabled: planTopic != null,
          child: Text(planTopic == null ? context.strings.plannedPathNone : context.strings.plannedPath)),
        CheckedPopupMenuItem(value: 'scan', checked: showScan, enabled: scanTopic != null,
          child: Text(scanTopic == null ? 'LiDAR (none)' : 'LiDAR $scanTopic')),
        for (final k in [CostmapKind.local, CostmapKind.global])
          CheckedPopupMenuItem(key: Key('layer-costmap-${k.name}'), value: 'costmap-${k.name}',
            checked: showCostmap[k] == true, enabled: costmapTopics[k] != null && !_costmapTooLarge.contains(k),
            child: Text(costmapTopics[k] == null ? context.strings.costmapNone(_costmapName(k))
                : _costmapTooLarge.contains(k) ? context.strings.costmapTooLarge(_costmapName(k)) : _costmapName(k))),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(key: const Key('map-3d-toggle'), value: '3d', checked: view3d, enabled: mapData.isNotEmpty,
          child: Text(context.strings.view3d)),
      ],
      onSelected: (v) {
        if (v.startsWith('costmap-')) {
          _toggleCostmap(CostmapKind.values.firstWhere((k) => 'costmap-${k.name}' == v));
          return;
        }
        setState(() {
        if (v == 'path') showPath = !showPath;
        if (v == 'scan') { showScan = !showScan; if (!showScan) scanPoints = []; }
        if (v == '3d') view3d = !view3d;
        });
      },
    );
    final back = IconButton(tooltip: context.strings.back, icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.maybePop(context));
    final settings = IconButton(key: const Key('map-topics'), tooltip: context.strings.topics,
      icon: const Icon(Icons.tune), onPressed: rosVersion == null ? null : openTopicSettings);
    final places = IconButton(key: const Key('map-places'), tooltip: context.strings.places,
      icon: const Icon(Icons.bookmarks_outlined), onPressed: showPlaces);
    return _glass(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4), child: wide
        ? Row(children: [back, const SizedBox(width: 4), Expanded(child: title), _toolToggle(), places, settings, layers])
        : Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [back, const SizedBox(width: 4),
              if (stackedTitle) const Spacer() else Expanded(child: title), places, settings, layers]),
            if (stackedTitle)
              Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Align(alignment: Alignment.centerLeft, child: title)),
            Padding(padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: SizedBox(width: double.infinity, child: _toolToggle())),
          ]));
  });

  Widget _banner(String text) => _glass(child: Row(children: [
    const Icon(Icons.error_outline, color: Color(0xFFB3261E), size: 18),
    const SizedBox(width: 8),
    Expanded(child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12))),
    IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 16),
      onPressed: () => setState(() => errorMessage = null)),
  ]));

  Widget _viewButtons() => Column(mainAxisSize: MainAxisSize.min, children: [
    _roundButton(Icons.fit_screen_outlined, 'Fit map', fitToMap, const Key('map-fit')),
    const SizedBox(height: 8),
    _roundButton(Icons.near_me_outlined, context.strings.centerOnRobot, robotPose == null ? null : centerOnRobot,
      const Key('map-center')),
  ]);

  Widget _roundButton(IconData icon, String tip, VoidCallback? onTap, Key key) => Material(
    color: context.card, shape: const CircleBorder(), elevation: 3,
    child: IconButton(key: key, tooltip: tip, icon: Icon(icon), onPressed: onTap),
  );

  String _meters(double? d) => d == null ? '—' : d < 10 ? '${d.toStringAsFixed(2)} m' : '${d.toStringAsFixed(1)} m';

  Widget _statusCard() {
    final g = goal, robot = robotPose;
    final title = TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: context.ink);
    final sub = TextStyle(color: context.muted, fontSize: 12);
    Widget content;
    if (tool == MapTool.setPose) {
      content = _setPoseCard(title, sub);
    } else if (patrol != null && patrol!.status != PatrolStatus.idle) {
      content = _patrolCard(title, sub);
    } else {
      switch (navState) {
        case NavState.idle when mapping:
          content = _mappingCard(title, sub);
        case NavState.idle:
          content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(view3d ? context.strings.tapFloor : context.strings.tapMap, style: title),
            if (robot == null) Padding(padding: const EdgeInsets.only(top: 4),
              child: Text(context.strings.robotPositionUnknown, key: const Key('robot-unknown'),
                style: TextStyle(color: Colors.orange.shade800, fontSize: 12))),
            if (patrol?.available == true && placeBook.usable.where((p) => p.frame == mapFrame).length >= 2)
              Align(alignment: Alignment.centerRight, child: TextButton.icon(key: const Key('patrol-open'),
                icon: const Icon(Icons.route, size: 18), label: Text(context.strings.patrol), onPressed: _openPatrolSetup)),
          ]);
        case NavState.preview:
          content = Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Container(padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(14)),
                child: Icon(Icons.location_on_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.strings.selectedDestination, style: title),
                if (robot != null) Text('${_meters(robot.distanceTo(g!))} away', style: sub),
              ])),
              IconButton(key: const Key('goal-clear'), tooltip: context.strings.clearDestination,
                onPressed: () => setState(() { goal = null; navState = NavState.idle; }),
                icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: 10),
            _headingControl(g!, robot),
            const SizedBox(height: 14),
            Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: [
              OutlinedButton.icon(key: const Key('goal-save-place'),
                icon: const Icon(Icons.bookmark_add_outlined, size: 18), label: Text(context.strings.savePlace),
                onPressed: () => savePlace(g)),
              FilledButton.icon(key: const Key('goal-go'),
                onPressed: rosVersion != null && connection?.isClosed == false ? sendGoal : null,
                icon: const Icon(Icons.navigation_outlined, size: 18), label: Text(context.strings.go)),
            ]),
          ]);
        case NavState.active:
          final eta = etaSeconds, start = _startDistance, left = distanceRemaining;
          // Nav2 reports 0 m left while it plans or recovers; that is not "arrived", so say what is happening
          // (and keep the bar moving) unless the robot really is at the goal.
          final farFromGoal = g != null && robot != null && math.sqrt(math.pow(g.x - robot.x, 2) + math.pow(g.y - robot.y, 2)) > 0.3;
          final activity = navActivity;
          final recovering = activity != null && isRecovery(activity);
          final planning = !recovering && (left == null || (left <= 0.01 && farFromGoal));
          final progress = planning || recovering || start == null || start <= 0 ? null : (1 - left! / start).clamp(0.0, 1.0);
          final notes = [
            // What Nav2 is doing (from its behavior tree), unless it is the plain "following the route".
            if (activity != null && activity != NavActivity.following && !planning && !recovering) navActivityText(context.strings, activity),
            if (eta != null && eta > 0 && !planning && !recovering) context.strings.navAboutSeconds(eta.round()),
            if (recoveries > 0) context.strings.navRecoveryCount(recoveries),
            if (navMode != NavMode.action) context.strings.navEstimatedFromPosition,
          ];
          content = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(context.strings.navigating, style: TextStyle(fontSize: 11, letterSpacing: 1.2, fontWeight: FontWeight.w700,
                  color: context.muted)),
                Text(planning ? context.strings.planningRoute : context.strings.distanceLeft(_meters(left)), key: const Key('nav-progress'), style: title),
                if (recovering) Text(navActivityText(context.strings, activity), key: const Key('nav-activity'),
                  style: sub.copyWith(color: const Color(0xFFB26A00), fontWeight: FontWeight.w700)),
                if (notes.isNotEmpty) Text(notes.join(' · '), style: sub, maxLines: 1, overflow: TextOverflow.ellipsis),
              ])),
              FilledButton.icon(key: const Key('nav-cancel'),
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E), foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact),
                onPressed: cancelGoal, icon: const Icon(Icons.stop, size: 18), label: Text(context.strings.cancel)),
            ]),
            const SizedBox(height: 10),
            ClipRRect(borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6)),
            // Repeated recoveries usually mean the robot is stuck or does not know where it is.
            if (recoveries >= 3) Padding(padding: const EdgeInsets.only(top: 8), child: Text(
              mapping ? context.strings.mappingFailHint : context.strings.lostHint,
              key: const Key('nav-stuck-hint'), style: sub)),
            // Something remembered in a costmap can be what blocks the way: offered once it keeps recovering.
            if ((recovering || recoveries >= 1) && navTools.canClearCostmaps) Align(alignment: Alignment.centerRight,
              child: _clearCostmapsButton()),
          ]);
        case NavState.succeeded:
        case NavState.canceled:
        case NavState.failed:
          final (icon, color, text) = switch (navState) {
            NavState.succeeded => (Icons.check_circle, const Color(0xFF2E7D32), context.strings.arrived),
            NavState.canceled => (Icons.cancel_outlined, Colors.blueGrey, context.strings.navigationCanceled),
            _ => (Icons.error, const Color(0xFFB3261E), context.strings.navigationFailed),
          };
          content = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [Row(children: [
            Icon(icon, color: color),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(text, key: const Key('nav-result'), style: title),
              if (resultDetail != null) Text(resultDetail!, style: sub),
              if (navState == NavState.failed) Text(mapping ? context.strings.mappingFailHint : context.strings.lostHint,
                key: const Key('nav-failed-hint'), style: sub),
            ])),
          ]), const SizedBox(height: 8), Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: [
            if (navState == NavState.failed && widget.robotLog != null) TextButton.icon(
              key: const Key('nav-open-log'), icon: const Icon(Icons.receipt_long_outlined), label: Text(context.strings.robotLog),
              onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RobotLogPage(log: widget.robotLog!)))),
            if (navState == NavState.failed && navTools.canClearCostmaps) _clearCostmapsButton(),
            TextButton(key: const Key('nav-dismiss'),
              onPressed: () { nav?.reset(); setState(() { navState = NavState.idle; goal = null; }); },
              child: Text(context.strings.ok)),
            if (navState == NavState.failed || navState == NavState.canceled) FilledButton.tonal(
              key: const Key('nav-retry'), onPressed: sendGoal, child: Text(context.strings.retry)),
          ])]);
      }
    }
    return ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560),
      child: SizedBox(width: double.infinity, child: _glass(padding: const EdgeInsets.all(14), child: content)));
  }

  Widget _setPoseCard(TextStyle title, TextStyle sub) {
    final p = pendingPose, cs = Theme.of(context).colorScheme;
    final online = rosVersion != null && connection?.isClosed == false;
    final match = previewMatch, g = guess;
    final fromSearch = g != null && p != null && identical(p, g.pose);
    final header = Row(children: [
      Expanded(child: Text(context.strings.setRobotPosition, style: title)),
      if (searching)
        const Padding(padding: EdgeInsets.all(12),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
      else
        TextButton.icon(key: const Key('pose-auto'), onPressed: mapData.isEmpty ? null : findPosition,
          icon: const Icon(Icons.travel_explore, size: 18), label: Text(context.strings.findAuto)),
    ]);
    final good = match != null && match >= PoseGuess.goodMatch;
    final fitLine = match == null ? null : Row(children: [
      Icon(good ? Icons.check_circle : Icons.warning_amber_rounded, size: 16,
        color: good ? const Color(0xFF2E7D32) : const Color(0xFFB26A00)),
      const SizedBox(width: 6),
      Expanded(child: Text(
        good ? context.strings.laserFits((match * 100).round())
            : context.strings.laserNotFits((match * 100).round()),
        key: const Key('pose-match'), style: sub.copyWith(color: context.ink))),
    ]);

    String? note;
    if (searching) {
      note = context.strings.comparingLaser;
    } else if (searchProblem != null) {
      note = searchProblem;
    } else if (fromSearch) {
      note = !g.good
          ? context.strings.noSpotFits
          : g.lookalikes > 0
              ? context.strings.foundLookalike(g.lookalikes + 1)
              : context.strings.foundIt;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      header,
      Text(note ?? (p == null ? context.strings.tapWhereRobot : context.strings.tapAndTurn),
        key: const Key('pose-note'),
        style: searchProblem != null && !searching ? sub.copyWith(color: cs.error) : sub),
      if (p != null) ...[
        if (fitLine != null) Padding(padding: const EdgeInsets.only(top: 6), child: fitLine),
        const SizedBox(height: 10),
        _headingControl(p, null, onChanged: (yaw) => setState(() => pendingPose = Pose2D(p.x, p.y, yaw)),
          label: context.strings.faces, keyPrefix: 'pose'),
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerRight, child: Wrap(alignment: WrapAlignment.end, spacing: 10, runSpacing: 8, children: [
          TextButton(key: const Key('pose-cancel'),
            onPressed: () => setState(() { pendingPose = null; guess = null; }),
            child: Text(context.strings.cancel)),
          FilledButton.icon(key: const Key('pose-confirm'),
            onPressed: online ? () => _setInitialPose(p) : null,
            icon: const Icon(Icons.my_location, size: 18), label: Text(context.strings.setPosition)),
        ])),
      ],
    ]);
  }

  /// Which way the robot faces on arrival: a dial to drag (it turns the arrow on the map too), 45° steps,
  /// and back to the direction of travel. Pressing and dragging on the map still works as well.
  Widget _headingControl(Pose2D g, Pose2D? robot,
      {ValueChanged<double>? onChanged, String? label, String keyPrefix = 'goal'}) {
    final cs = Theme.of(context).colorScheme;
    // Shown 0..359 (people read "270°" more easily than "-90°"); the 45° steps work from the same value.
    final degrees = ((g.yaw * 180 / math.pi).round() % 360 + 360) % 360;
    void setYaw(double yaw) {
      final y = math.atan2(math.sin(yaw), math.cos(yaw));
      if (onChanged != null) {
        onChanged(y);
      } else {
        setState(() => goal = Pose2D(g.x, g.y, y));
      }
    }
    void step(int deg) {
      final snapped = ((degrees + deg) / 45).round() * 45;
      setYaw(snapped * math.pi / 180);
    }
    final travel = robot == null ? null : math.atan2(g.y - robot.y, g.x - robot.x);
    const dense = VisualDensity(horizontal: -2, vertical: -2);
    final small = TextStyle(fontSize: 12, color: context.muted);
    return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      Tooltip(message: context.strings.dragHeading,
        child: HeadingDial(key: Key('$keyPrefix-heading-dial'), yaw: g.yaw, onChanged: setYaw, size: 56)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(keyPrefix == 'goal' ? context.strings.goalFacesOnArrival('$degrees') : '${label ?? context.strings.faces} $degrees°', key: Key('$keyPrefix-heading'),
          style: TextStyle(fontWeight: FontWeight.w700, color: context.ink)),
        Wrap(spacing: 10, children: [
          Text('X ${g.x.toStringAsFixed(2)} m', key: Key('$keyPrefix-metric-X'), style: small),
          Text('Y ${g.y.toStringAsFixed(2)} m', key: Key('$keyPrefix-metric-Y'), style: small),
        ]),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          IconButton(key: Key('$keyPrefix-heading-left'), tooltip: context.strings.turnLeft45, visualDensity: dense,
            onPressed: () => step(45), icon: const Icon(Icons.rotate_left)),
          IconButton(key: Key('$keyPrefix-heading-right'), tooltip: context.strings.turnRight45, visualDensity: dense,
            onPressed: () => step(-45), icon: const Icon(Icons.rotate_right)),
          if (travel != null)
            TextButton(key: const Key('goal-heading-travel'), onPressed: () => setYaw(travel),
              style: TextButton.styleFrom(foregroundColor: cs.primary, visualDensity: dense),
              child: Text(context.strings.travelDirection)),
        ]),
      ])),
    ]);
  }





}

/// Occupancy colours, calm like a floor plan: unknown is see-through (the page shows), free floor is the
/// lightest tone, walls are the strongest, and intermediate costs shade from floor towards blue.
class MapPalette {
  const MapPalette({required this.background, required this.floor, required this.wall, required this.cost});
  final Color background, floor, wall, cost;

  static const light = MapPalette(background: Color(0xFFE6ECF2), floor: Color(0xFFFFFFFF),
    wall: Color(0xFF34465A), cost: Color(0xFF9CC3EA));
  static const dark = MapPalette(background: Color(0xFF0B1218), floor: Color(0xFF223140),
    wall: Color(0xFFC3D2DF), cost: Color(0xFF3F6A93));
  static MapPalette of(BuildContext context) => context.isDark ? dark : light;

  /// Colour of one cell; null = unknown (transparent).
  Color? cell(int value) => value == -1 ? null
      : value <= 0 ? floor
      : value >= 100 ? wall
      : Color.lerp(floor, cost, 0.35 + 0.65 * value / 100)!;

  /// RGBA bytes for every occupancy value -1..100, so rasterising a large map does no per-cell Color work.
  Uint8List rgbaTable() {
    final table = Uint8List(102 * 4);
    for (var v = -1; v <= 100; v++) {
      final c = cell(v), i = (v + 1) * 4;
      if (c == null) continue; // all zero: transparent
      table[i] = (c.r * 255).round();
      table[i + 1] = (c.g * 255).round();
      table[i + 2] = (c.b * 255).round();
      table[i + 3] = 255;
    }
    return table;
  }
}

/// Square window (in grid cells, y counted from the map bottom) around the known cells plus a margin,
/// so a large SLAM canvas with a small explored area opens framed on what is known. Falls back to the
/// whole map when nothing is known.
Rect knownArea(List<int> cells, int width, int height, double resolution) {
  var minX = width, minY = height, maxX = -1, maxY = -1;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      if (cells[y * width + x] == -1) continue;
      if (x < minX) minX = x;
      if (x > maxX) maxX = x;
      if (y < minY) minY = y;
      if (y > maxY) maxY = y;
    }
  }
  if (maxX < 0) return Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  final margin = math.max(2, (0.5 / resolution).round()); // ~0.5 m around the explored area
  final minSide = (2.0 / resolution).ceil(); // never zoom closer than a 2 m window
  var side = math.max(math.max(maxX - minX, maxY - minY) + 1 + 2 * margin, minSide);
  side = math.min(side, math.max(width, height));
  final w = math.min(side, width).toDouble(), h = math.min(side, height).toDouble();
  final cx = (minX + maxX + 1) / 2, cy = (minY + maxY + 1) / 2;
  final left = (cx - w / 2).clamp(0.0, width - w), bottom = (cy - h / 2).clamp(0.0, height - h);
  return Rect.fromLTWH(left, bottom, w, h);
}

class MapPainter extends CustomPainter {
  MapPainter({required this.image, required this.mapData, required this.width, required this.height,
    required this.resolution, required this.origin, required this.robot, required this.goal,
    this.goalActive = false, this.path = const [], this.scan = const [], this.dragAnchor, this.dragYaw,
    this.setPose = false, this.places = const [], this.fleetRobots = const [], this.pendingPose,
    this.palette = MapPalette.light, this.previewScan = const [], this.costmaps = const []});

  /// Nav2's costmaps, drawn over the grid and under everything else.
  final List<CostmapOverlay> costmaps;

  /// The laser as it would sit with the robot at [pendingPose] (Set pose), drawn in purple.
  final List<math.Point<double>> previewScan;

  final MapPalette palette;

  final ui.Image? image; // pre-rendered grid; null until the first rasterisation finishes
  final List<int> mapData;
  final int width, height;
  final double resolution;
  final Pose2D origin;
  final Pose2D? robot, goal;

  /// Where the person says the robot is (Set pose), drawn in purple until confirmed.
  final Pose2D? pendingPose;
  final bool goalActive, setPose;
  final List<math.Point<double>> path, scan;
  final Offset? dragAnchor;
  final double? dragYaw;
  /// Saved places, drawn as labelled pins.
  final List<(String, Pose2D)> places;
  /// Named robots whose poses are already expressed in this map's frame.
  final List<(String, Pose2D)> fleetRobots;

  bool get showRobot => robot != null;

  Offset _px(Size size, double x, double y) {
    final p = worldToScreen(x, y, size.width, size.height, width, height, resolution, origin.x, origin.y, origin.yaw);
    return Offset(p.x, p.y);
  }

  /// Screen angle of a world heading (screen y points down; the map origin may be rotated).
  double _screenAngle(double yaw) => -(yaw - origin.yaw);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / width;
    final grid = image;
    if (grid != null) {
      canvas.drawImageRect(grid, Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Offset.zero & size,
          // Smoothed so walls read as lines, not stair-stepped pixels.
          Paint()..filterQuality = FilterQuality.medium);
    } else {
      final paint = Paint();
      final clip = canvas.getLocalClipBounds();
      final x0 = math.max(0, (clip.left / cell).floor()), x1 = math.min(width, (clip.right / cell).ceil());
      final r0 = math.max(0, (clip.top / cell).floor()), r1 = math.min(height, (clip.bottom / cell).ceil());
      for (var row = r0; row < r1; row++) {
        for (var x = x0; x < x1; x++) {
          final c = palette.cell(mapData[(height - 1 - row) * width + x]);
          if (c == null) continue;
          paint.color = c;
          canvas.drawRect(Rect.fromLTWH(x * cell, row * cell, cell, cell), paint);
        }
      }
    }
    final metre = cell / resolution; // canvas px per metre
    for (final c in costmaps) {
      final (topLeft, topRight, bottomLeft) = c.corners();
      final p0 = _px(size, topLeft.x, topLeft.y), p1 = _px(size, topRight.x, topRight.y);
      final p2 = _px(size, bottomLeft.x, bottomLeft.y);
      final w = c.width.toDouble(), h = c.height.toDouble();
      // Picture pixels → canvas: the picture's own x and y axes land on the vectors p0→p1 and p0→p2.
      final m = Float64List.fromList([
        (p1.dx - p0.dx) / w, (p1.dy - p0.dy) / w, 0, 0,
        (p2.dx - p0.dx) / h, (p2.dy - p0.dy) / h, 0, 0,
        0, 0, 1, 0,
        p0.dx, p0.dy, 0, 1,
      ]);
      canvas.save();
      canvas.transform(m);
      canvas.drawImageRect(c.image, Rect.fromLTWH(0, 0, w, h), Rect.fromLTWH(0, 0, w, h),
          Paint()..filterQuality = FilterQuality.low);
      canvas.restore();
    }

    if (scan.isNotEmpty) {
      final dots = Paint()..color = const Color(0xFFFF6D3F).withValues(alpha: 0.75)..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.6, 0.035 * metre);
      canvas.drawPoints(ui.PointMode.points, [for (final p in scan) _px(size, p.x, p.y)], dots);
    }
    if (previewScan.isNotEmpty) {
      final dots = Paint()..color = const Color(0xFF8E24AA).withValues(alpha: 0.85)..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(2.0, 0.045 * metre);
      canvas.drawPoints(ui.PointMode.points, [for (final p in previewScan) _px(size, p.x, p.y)], dots);
    }
    if (path.length > 1) {
      final line = ui.Path()..moveTo(_px(size, path.first.x, path.first.y).dx, _px(size, path.first.x, path.first.y).dy);
      for (final p in path.skip(1)) {
        final o = _px(size, p.x, p.y);
        line.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(line, Paint()..style = PaintingStyle.stroke..color = const Color(0xCC1E88E5)
        ..strokeWidth = math.max(2.5, 0.06 * metre)..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round);
    }
    // Labels never sit on each other: one that would overlap an earlier one moves down below it (two
    // places saved at almost the same spot both stay readable).
    final taken = <Rect>[];
    for (final (name, at) in places) {
      final o = _px(size, at.x, at.y);
      final r = math.max(5.0, 0.1 * metre);
      canvas.drawCircle(o, r, Paint()..color = const Color(0xFF6A1B9A));
      canvas.drawCircle(o, r, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 1.5);
      final label = TextPainter(text: TextSpan(text: name, style: TextStyle(color: const Color(0xFF4A148C),
          fontSize: math.max(10.0, 0.25 * metre), fontWeight: FontWeight.w700,
          shadows: const [Shadow(color: Colors.white, blurRadius: 3)])), textDirection: TextDirection.ltr)..layout();
      var box = Rect.fromLTWH(o.dx - label.width / 2, o.dy + r + 2, label.width, label.height);
      for (var i = 0; i < 8 && taken.any((t) => t.overlaps(box)); i++) {
        box = box.shift(Offset(0, label.height));
      }
      taken.add(box);
      label.paint(canvas, box.topLeft);
    }
    final g = goal;
    if (g != null) {
      _marker(canvas, _px(size, g.x, g.y), _screenAngle(g.yaw), math.max(9.0, 0.18 * metre),
        goalActive ? const Color(0xFF2E7D32) : const Color(0xFF43A047));
    }

    final anchor = dragAnchor;
    if (anchor != null) {
      final yaw = dragYaw;
      final color = setPose ? const Color(0xFF8E24AA) : const Color(0xFF43A047);
      if (yaw == null) {
        canvas.drawCircle(anchor, math.max(8.0, 0.2 * metre), Paint()..color = color.withValues(alpha: 0.5));
      } else {
        _arrow(canvas, anchor, _screenAngle(yaw), math.max(14.0, 0.4 * metre), color, flag: true);
      }
    }
    final r = robot;
    if (r != null) {
      _marker(canvas, _px(size, r.x, r.y), _screenAngle(r.yaw), math.max(10.0, 0.22 * metre),
        const Color(0xFF1565C0), halo: true);
    }
    final pp = pendingPose; // above the robot: it is what the person is editing
    if (pp != null) {
      _marker(canvas, _px(size, pp.x, pp.y), _screenAngle(pp.yaw), math.max(10.0, 0.22 * metre),
        const Color(0xFF8E24AA), halo: true);
    }
    // Markers first, then name tags in pills that move aside when two robots stand close together.
    final radius = math.max(10.0, 0.22 * metre);
    for (final (_, pose) in fleetRobots) {
      _marker(canvas, _px(size, pose.x, pose.y), _screenAngle(pose.yaw), radius, const Color(0xFF1565C0), halo: true);
    }
    final placed = <Rect>[];
    for (final (name, pose) in fleetRobots) {
      final at = _px(size, pose.x, pose.y);
      final label = TextPainter(text: TextSpan(text: name, style: const TextStyle(
        color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout();
      final w = label.width + 12, h = label.height + 4;
      final options = [
        Rect.fromLTWH(at.dx - w / 2, at.dy + radius + 4, w, h), // below
        Rect.fromLTWH(at.dx - w / 2, at.dy - radius - 4 - h, w, h), // above
        Rect.fromLTWH(at.dx + radius + 4, at.dy - h / 2, w, h), // right
        Rect.fromLTWH(at.dx - radius - 4 - w, at.dy - h / 2, w, h), // left
      ];
      final box = options.firstWhere((r) => !placed.any((p) => p.overlaps(r)), orElse: () => options.first);
      placed.add(box);
      canvas.drawRRect(RRect.fromRectAndRadius(box, Radius.circular(h / 2)),
          Paint()..color = const Color(0xFF1565C0).withValues(alpha: 0.92));
      label.paint(canvas, box.topLeft + const Offset(6, 2));
    }
  }

  /// A disc with a white chevron pointing along its heading (robot: blue with a halo; goal: green).
  void _marker(Canvas canvas, Offset at, double angle, double radius, Color color, {bool halo = false}) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    if (halo) canvas.drawCircle(Offset.zero, radius * 1.6, Paint()..color = color.withValues(alpha: 0.16));
    {
      // A beam in the facing direction (as map apps do), readable at any size and angle.
      final beam = ui.Path()
        ..moveTo(0, 0)
        ..arcTo(Rect.fromCircle(center: Offset.zero, radius: radius * 3.2), -0.42, 0.84, false)
        ..close();
      canvas.drawPath(beam, Paint()..shader = ui.Gradient.radial(Offset.zero, radius * 3.2,
          [color.withValues(alpha: 0.45), color.withValues(alpha: 0)]));
    }
    canvas.drawCircle(Offset.zero, radius, Paint()..color = color);
    canvas.drawCircle(Offset.zero, radius, Paint()..color = Colors.white..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2.0, radius * 0.16));
    final chevron = ui.Path()
      // Long and slim (the point is much farther out than the back corners), so at no angle can the
      // back be read as the point.
      ..moveTo(radius * 0.8, 0)
      ..lineTo(-radius * 0.45, -radius * 0.34)
      ..lineTo(-radius * 0.18, 0)
      ..lineTo(-radius * 0.45, radius * 0.34)
      ..close();
    canvas.drawPath(chevron, Paint()..color = Colors.white);
    canvas.restore();
  }

  /// A heading marker: a disc (robot body) or a flag dot, with an arrow along [angle].
  void _arrow(Canvas canvas, Offset at, double angle, double radius, Color color, {bool flag = false}) {
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.rotate(angle);
    final fill = Paint()..color = color;
    final outline = Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = math.max(2.0, radius * 0.18);
    if (flag) {
      canvas.drawCircle(Offset.zero, radius * 0.55, fill);
      canvas.drawCircle(Offset.zero, radius * 0.55, outline);
    }
    final tip = ui.Path()
      ..moveTo(radius * 1.7, 0)
      ..lineTo(radius * 0.55, -radius * 0.55)
      ..lineTo(radius * 0.55, radius * 0.55)
      ..close();
    canvas.drawPath(tip, fill);
    canvas.drawPath(tip, outline);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// Asks for a map name (it owns its text controller, so closing animations never touch a disposed one).
class _SaveMapDialog extends StatefulWidget {
  const _SaveMapDialog({required this.onRobot});
  final bool onRobot;

  @override
  State<_SaveMapDialog> createState() => _SaveMapDialogState();
}

class _SaveMapDialogState extends State<_SaveMapDialog> {
  late final controller = TextEditingController(text: defaultMapName(DateTime.now()));

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    key: const Key('save-map-dialog'),
    title: Text(context.strings.saveMap),
    content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      TextField(key: const Key('save-map-name'), controller: controller, autofocus: true,
        decoration: InputDecoration(labelText: context.strings.name)),
      const SizedBox(height: 12),
      Text(widget.onRobot
          ? context.strings.savedOnRobotAndPhone
          : context.strings.savedOnPhoneOnly,
        style: TextStyle(color: context.muted)),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('save-map-confirm'),
        onPressed: () => Navigator.pop(context, mapFileName(controller.text)), child: Text(context.strings.save)),
    ],
  );
}

class _PlaceNameDialog extends StatefulWidget {
  const _PlaceNameDialog();

  @override
  State<_PlaceNameDialog> createState() => _PlaceNameDialogState();
}

class _PlaceNameDialogState extends State<_PlaceNameDialog> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.saveAsPlace),
    content: TextField(key: const Key('place-name'), controller: _name, autofocus: true,
      decoration: InputDecoration(labelText: context.strings.name, hintText: context.strings.placeHint,
        border: const OutlineInputBorder()),
      onSubmitted: (v) => Navigator.pop(context, v)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(key: const Key('place-save'), onPressed: () => Navigator.pop(context, _name.text),
        child: Text(context.strings.save)),
    ],
  );
}

/// A small compass for a goal's heading, drawn the way the map shows it (0° points right, counter-clockwise
/// positive). Dragging anywhere on it points the arrow at the finger.
class HeadingDial extends StatelessWidget {
  const HeadingDial({super.key, required this.yaw, required this.onChanged, this.size = 64});
  final double yaw;
  final ValueChanged<double> onChanged;
  final double size;

  void _point(Offset local) {
    final c = Offset(size / 2, size / 2);
    final d = local - c;
    if (d.distance < 4) return;
    // Screen y grows downward, map y upward. Snapped to 5°: a finger is not more precise than that.
    final deg = (math.atan2(-d.dy, d.dx) * 180 / math.pi / 5).round() * 5;
    onChanged(deg * math.pi / 180);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(label: context.strings.arrivalHeading((yaw * 180 / math.pi).round()), child: GestureDetector(
      onPanDown: (d) => _point(d.localPosition),
      onPanUpdate: (d) => _point(d.localPosition),
      child: SizedBox(width: size, height: size, child: CustomPaint(
        painter: _HeadingDialPainter(yaw, cs.primary, cs.outlineVariant, cs.surfaceContainerHighest))),
    ));
  }
}

class _HeadingDialPainter extends CustomPainter {
  _HeadingDialPainter(this.yaw, this.arrow, this.ring, this.fill);
  final double yaw;
  final Color arrow, ring, fill;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 - 2;
    canvas.drawCircle(c, r, Paint()..color = fill);
    canvas.drawCircle(c, r, Paint()..color = ring..style = PaintingStyle.stroke..strokeWidth = 2);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final o = c + Offset(math.cos(a), -math.sin(a)) * (r - 4);
      canvas.drawCircle(o, i.isEven ? 2.2 : 1.4, Paint()..color = ring);
    }
    final dir = Offset(math.cos(yaw), -math.sin(yaw));
    final tip = c + dir * (r - 6);
    final side = Offset(-dir.dy, dir.dx);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo((c + side * 7 - dir * 6).dx, (c + side * 7 - dir * 6).dy)
      ..lineTo((c - dir * 2).dx, (c - dir * 2).dy)
      ..lineTo((c - side * 7 - dir * 6).dx, (c - side * 7 - dir * 6).dy)
      ..close();
    canvas.drawPath(path, Paint()..color = arrow);
  }

  @override
  bool shouldRepaint(covariant _HeadingDialPainter old) =>
      old.yaw != yaw || old.arrow != arrow || old.ring != ring || old.fill != fill;
}

/// Names the map shown as a floor and the map file on the robot that loads it; owns its text fields
/// (they live through the closing animation).
class _FloorNameDialog extends StatefulWidget {
  const _FloorNameDialog(this.name, this.mapFile);
  final String name, mapFile;

  @override
  State<_FloorNameDialog> createState() => _FloorNameDialogState();
}

class _FloorNameDialogState extends State<_FloorNameDialog> {
  late final name = TextEditingController(text: widget.name);
  late final file = TextEditingController(text: widget.mapFile);

  @override
  void dispose() {
    name.dispose();
    file.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.floor),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(key: const Key('floor-name-field'), controller: name, autofocus: true,
        decoration: InputDecoration(labelText: context.strings.name, hintText: context.strings.floorHint)),
      const SizedBox(height: 8),
      TextField(key: const Key('floor-map-field'), controller: file,
        decoration: InputDecoration(labelText: context.strings.floorMapFile,
          hintText: '/home/ubuntu/maps/1f.yaml', helperText: context.strings.floorMapFileHelp)),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, (name.text, file.text)), child: Text(context.strings.save)),
    ]);
}
