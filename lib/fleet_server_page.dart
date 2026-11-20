import 'app_language.dart';
import 'dart:async';
import 'app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'fleet_server_client.dart';
import 'map_geometry.dart';
import 'map_page.dart' show MapPainter;

/// Connect to an on-site server without joining the robot's ROS network from this device.
class FleetServerConnectPage extends StatefulWidget {
  const FleetServerConnectPage({super.key});

  @override
  State<FleetServerConnectPage> createState() => _FleetServerConnectPageState();
}

class _FleetServerConnectPageState extends State<FleetServerConnectPage> {
  final _url = TextEditingController(text: 'http://127.0.0.1:8766');
  final _token = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) _url.text = prefs.getString('fleet_server_url') ?? _url.text;
    });
  }

  Future<void> _connect() async {
    if (_busy) return;
    setState(() { _busy = true; _error = null; });
    FleetServerClient? client;
    try {
      client = FleetServerClient(_url.text.trim(), _token.text.trim());
      final state = await client.state();
      if (!mounted) { client.close(); return; }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fleet_server_url', _url.text.trim());
      if (!mounted) { client.close(); return; }
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) =>
        FleetServerDashboard(client: client!, initialState: state)));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      client?.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() { _url.dispose(); _token.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.strings.fleetServerPreview)),
    body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 500),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(context.strings.connectToSite, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(context.strings.siteServerHelp),
          const SizedBox(height: 24),
          TextField(key: const Key('fleet-server-url'), controller: _url,
            decoration: InputDecoration(labelText: context.strings.serverUrl, hintText: 'http://factory-server:8766')),
          const SizedBox(height: 12),
          TextField(key: const Key('fleet-server-token'), controller: _token, obscureText: true,
            decoration: InputDecoration(labelText: context.strings.operatorToken)),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          const SizedBox(height: 20),
          FilledButton(key: const Key('fleet-server-connect'), onPressed: _busy ? null : _connect,
            child: Text(_busy ? context.strings.connecting : context.strings.openFleetDashboard)),
        ])),
    )),
  );
}

class FleetServerDashboard extends StatefulWidget {
  const FleetServerDashboard({super.key, required this.client, required this.initialState});
  final FleetServerClient client;
  final Map<String, dynamic> initialState;

  @override
  State<FleetServerDashboard> createState() => _FleetServerDashboardState();
}

class _FleetServerDashboardState extends State<FleetServerDashboard> {
  late Map<String, dynamic> _state = widget.initialState;
  Map<String, dynamic> _map = const {};
  Timer? _timer;
  bool _refreshing = false;
  bool _submitting = false;
  int _polls = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadMap();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _loadMap() async {
    try {
      final map = await widget.client.map();
      if (mounted) setState(() => _map = map);
    } catch (error) { if (mounted) setState(() => _error = '$error'); }
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final state = await widget.client.state();
      if (mounted) setState(() { _state = state; _error = null; });
      // The map can be megabytes: fetch it again only when the server says it changed.
      final version = state['mapVersion'];
      if (_map.isEmpty || (version is int && version != _map['version']) || (version == null && ++_polls % 15 == 0)) {
        await _loadMap();
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally { _refreshing = false; }
  }

  List<Map<String, dynamic>> _list(String key) => [
    for (final item in _state[key] is List ? _state[key] as List : const [])
      if (item is Map) Map<String, dynamic>.from(item),
  ];

  Future<void> _newTask() async {
    if (_submitting || _error != null || _state['connected'] != true) return;
    final busy = _list('tasks').where((t) => ['queued', 'active', 'canceling'].contains(t['status']))
        .map((t) => t['robot']).toSet();
    final robots = _list('robots').where((r) => r['status'] == 'online' && !busy.contains(r['id'])).toList();
    final places = [for (final p in _state['places'] is List ? _state['places'] as List : const []) '$p'];
    if (robots.isEmpty || places.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.strings.needFreeRobotDest)));
      return;
    }
    setState(() => _submitting = true);
    String robot = '${robots.first['id']}', destination = places.first;
    final selected = await showDialog<(String, String)>(context: context, builder: (context) =>
      StatefulBuilder(builder: (context, update) => AlertDialog(
        title: Text(context.strings.requestTransport),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(initialValue: robot, isExpanded: true, itemHeight: null,
            decoration: InputDecoration(labelText: context.strings.robot),
            items: [for (final r in robots) DropdownMenuItem(value: '${r['id']}', child: Text('${r['id']}'))],
            onChanged: (value) { if (value != null) update(() => robot = value); }),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: destination,
            isExpanded: true, itemHeight: null,
            decoration: InputDecoration(labelText: context.strings.destination),
            items: [for (final place in places) DropdownMenuItem(value: place, child: Text(place))],
            onChanged: (value) { if (value != null) update(() => destination = value); }),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, (robot, destination)),
            child: Text(context.strings.requestTask)),
        ],
      )));
    if (mounted) setState(() => _submitting = false);
    if (selected == null || !mounted) return;
    setState(() => _submitting = true);
    try { await widget.client.createTask(selected.$1, selected.$2); await _refresh(); }
    catch (error) { if (mounted) setState(() => _error = '$error'); }
    finally { if (mounted) setState(() => _submitting = false); }
  }

  Future<void> _cancel(String id) async {
    try { await widget.client.cancelTask(id); await _refresh(); }
    catch (error) { if (mounted) setState(() => _error = '$error'); }
  }

  Future<void> _stopAll() async {
    try { await widget.client.stopAll(); await _refresh(); }
    catch (error) { if (mounted) setState(() => _error = '$error'); }
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final robots = _list('robots'), tasks = _list('tasks'), events = _list('events');
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.fleetOperations), actions: [
        IconButton(tooltip: context.strings.refresh, onPressed: _refresh, icon: const Icon(Icons.refresh)),
      ]),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        if (_error != null) Card(color: context.cs.errorContainer, child: Padding(
          padding: const EdgeInsets.all(12), child: Text(context.strings.dashboardStale('$_error')))),
        Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12, runSpacing: 8, children: [
            Text(context.strings.robotsCountStatus(robots.length, _error != null ? context.strings.statusUnavailable
                : _state['connected'] == true ? context.strings.connectedShort : context.strings.robotNetworkOffline),
              style: Theme.of(context).textTheme.titleLarge),
            Wrap(spacing: 8, children: [
              FilledButton.icon(key: const Key('fleet-task-new'),
                onPressed: _submitting || _error != null || _state['connected'] != true ? null : _newTask,
                icon: const Icon(Icons.add), label: Text(context.strings.requestTask)),
              FilledButton.icon(key: const Key('fleet-stop-all'), onPressed: _stopAll,
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB3261E), foregroundColor: Colors.white),
                icon: const Icon(Icons.stop), label: Text(context.strings.stopAll)),
            ]),
          ]),
        const SizedBox(height: 16),
        if (robots.isEmpty) Card(child: Padding(padding: EdgeInsets.all(16),
          child: Text(context.strings.noRobotsFoundServer))),
        Wrap(spacing: 12, runSpacing: 12, children: [
          for (final robot in robots) SizedBox(width: 280, child: _robotCard(robot, tasks)),
        ]),
        const SizedBox(height: 24),
        Text(context.strings.sharedMap, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        _mapWidget(robots),
        const SizedBox(height: 24),
        Text(context.strings.taskQueue, style: Theme.of(context).textTheme.titleLarge),
        if (tasks.isEmpty) ListTile(title: Text(context.strings.noTasksYet)),
        for (final task in tasks) ListTile(key: Key('task-${task['id']}'),
          title: Text('${task['robot']} → ${task['destination']}'),
          subtitle: Text([taskStatusLabel('${task['status']}'), if (task['step'] != null) '${task['step']}',
            if (task['error'] != null) '${task['error']}',
            '${task['updatedAt']}'].join(' · ')),
          // Until the robot confirms, asking again is allowed.
          trailing: ['queued', 'active', 'canceling', 'cancel_unconfirmed'].contains(task['status'])
            ? IconButton(tooltip: task['status'] == 'active' || task['status'] == 'queued' ? context.strings.cancelTask : context.strings.askAgainCancel,
                onPressed: () => _cancel('${task['id']}'),
                icon: Icon(task['status'] == 'cancel_unconfirmed' ? Icons.warning_amber : Icons.cancel_outlined)) : null),
        const SizedBox(height: 20),
        ExpansionTile(title: Text(context.strings.recentEvents), children: [
        for (final event in events.reversed.take(20)) ListTile(dense: true,
          title: Text('${event['type']} · ${event['robot'] ?? event['task']?['robot'] ?? ''}'),
          subtitle: Text('${event['at']}')),
        ]),
      ]),
    );
  }

  Widget _robotCard(Map<String, dynamic> robot, List<Map<String, dynamic>> tasks) {
    final active = tasks.where((t) => t['robot'] == robot['id'] && ['active', 'canceling'].contains(t['status'])).firstOrNull;
    final pose = robot['pose'];
    final battery = robot['battery'];
    return Card(key: Key('server-robot-${robot['id']}'), child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${robot['id']} · ${robot['status'] == 'stale' ? 'no recent data' : robot['status']}'
            '${robot['floor'] != null ? ' · ${robot['floor']}' : ''}',
          style: Theme.of(context).textTheme.titleMedium),
        Text(context.strings.batteryLine(battery is num ? '${(battery * 100).round()}%' : context.strings.unknown)),
        Text(context.strings.positionLine(pose is Map && pose['x'] is num && pose['y'] is num ? '${(pose['x'] as num).toStringAsFixed(2)}, ${(pose['y'] as num).toStringAsFixed(2)} m' : context.strings.unknown)),
        Text(context.strings.taskLine(active == null ? context.strings.idle : '${active['destination']}')),
        Text(context.strings.errorLine('${robot['error'] ?? context.strings.none}')),
      ])));
  }

  Widget _mapWidget(List<Map<String, dynamic>> robots) {
    final width = _map['width'], height = _map['height'], data = _map['data'];
    if (width is! int || height is! int || data is! List || data.length != width * height ||
        width <= 0 || height <= 0) {
      final problem = _state['mapProblem'];
      return Card(child: Padding(padding: const EdgeInsets.all(24),
        child: Text(problem is String ? problem : context.strings.waitingSiteMap)));
    }
    final origin = _map['origin'];
    final o = origin is Map ? origin : const {};
    final q = o['quaternion'];
    final quaternion = q is Map ? q : const {'x': 0, 'y': 0, 'z': 0, 'w': 1};
    final markers = <(String, Pose2D)>[
      for (final robot in robots)
        if (robot['pose'] case final Map pose)
          if (pose['x'] is num && pose['y'] is num)
            ('${robot['id']}', Pose2D((pose['x'] as num).toDouble(),
              (pose['y'] as num).toDouble(), (pose['yaw'] as num?)?.toDouble() ?? 0)),
    ];
    return ConstrainedBox(constraints: const BoxConstraints(maxHeight: 500),
      child: AspectRatio(aspectRatio: width / height, child: CustomPaint(
        key: const Key('server-fleet-map'),
        painter: MapPainter(image: null, mapData: List<int>.from(data), width: width, height: height,
          resolution: (_map['resolution'] as num).toDouble(),
          origin: Pose2D((o['x'] as num?)?.toDouble() ?? 0, (o['y'] as num?)?.toDouble() ?? 0,
            yawOf(quaternion)), robot: null, goal: null, fleetRobots: markers),
      )));
  }
}

/// A server task status in words; a cancel counts only once the robot confirms it.
String taskStatusLabel(String status) => switch (status) {
  'canceling' => 'Canceling (waiting for the robot)',
  'cancel_unconfirmed' => 'Cancel not confirmed: check the robot',
  'interrupted' => 'Interrupted by a server restart',
  _ => status,
};
