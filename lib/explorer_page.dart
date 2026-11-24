import 'app_language.dart';
import 'dart:async';
import 'app_theme.dart';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'message_schema.dart';
import 'plot_page.dart';
import 'plotting.dart';
import 'relay_access.dart';
import 'topic_health_page.dart';
import 'ros_connection.dart';
import 'widgets/status_panel.dart';
import 'widgets/throttled_rebuild.dart';

/// Types whose messages are large (images, point clouds, grids): shown at most once a second, and the
/// JSON preview truncates their arrays, so inspecting a camera topic cannot freeze the phone.
const heavyTypes = {
  'sensor_msgs/Image', 'sensor_msgs/CompressedImage', 'sensor_msgs/PointCloud2', 'sensor_msgs/PointCloud',
  'nav_msgs/OccupancyGrid', 'map_msgs/OccupancyGridUpdate', 'octomap_msgs/Octomap', 'sensor_msgs/CameraInfo',
  'theora_image_transport/Packet', 'grid_map_msgs/GridMap',
};

bool isHeavyType(String? type) => type != null && heavyTypes.contains(normalizeType(type));

/// A copy of [value] safe to print: lists longer than [maxItems] and strings longer than [maxChars]
/// (base64 image data) are cut, with a note of what was left out.
Object? truncateForDisplay(Object? value, {int maxItems = 12, int maxChars = 160}) {
  if (value is Map) {
    return {for (final e in value.entries) '${e.key}': truncateForDisplay(e.value, maxItems: maxItems, maxChars: maxChars)};
  }
  if (value is List) {
    final head = [for (final v in value.take(maxItems)) truncateForDisplay(v, maxItems: maxItems, maxChars: maxChars)];
    return value.length > maxItems ? [...head, '… ${value.length - maxItems} more (${value.length} items)'] : head;
  }
  if (value is String && value.length > maxChars) {
    return '${value.substring(0, maxChars)}… (${value.length} chars)';
  }
  return value;
}

String prettyJson(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

/// Topics, nodes and services of the robot over one rosbridge connection, with live topic inspection
/// and service calls.
class ExplorerPage extends StatefulWidget {
  const ExplorerPage({super.key, required this.ip, required this.port, this.connectionFactory = RosConnection.new});
  final String ip;
  final String port;
  final RosConnection Function(String, String) connectionFactory;

  @override
  State<ExplorerPage> createState() => ExplorerPageState();
}

class ExplorerPageState extends State<ExplorerPage> {
  RosConnection? connection;
  String? errorMessage;
  bool loading = true;
  Map<String, String> topicTypes = {};
  List<String> nodes = [];
  List<String> services = [];
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    try {
      final client = widget.connectionFactory(widget.ip, widget.port);
      connection = client;
      client.messages.listen((_) {}, onDone: () {
        if (mounted) setState(() => errorMessage = client.lastError ?? context.strings.robotDisconnectedShort);
      });
      await client.ready;
      await refresh();
    } catch (e) {
      if (mounted) setState(() { errorMessage = context.strings.connectionFailed('$e'); loading = false; });
    }
  }

  Future<void> refresh() async {
    final client = connection;
    if (client == null || client.isClosed) return;
    setState(() { loading = true; errorMessage = null; });
    try {
      final topics = await client.call('/rosapi/topics');
      final names = List<String>.from(topics['topics'] as List? ?? const []);
      final types = List<String>.from(topics['types'] as List? ?? const []);
      final nodeList = List<String>.from((await client.call('/rosapi/nodes'))['nodes'] as List? ?? const []);
      final serviceList = List<String>.from((await client.call('/rosapi/services'))['services'] as List? ?? const []);
      if (!mounted) return;
      setState(() {
        topicTypes = {for (var i = 0; i < names.length; i++) names[i]: i < types.length ? types[i] : ''};
        nodes = nodeList..sort();
        services = serviceList..sort();
        loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { errorMessage = context.strings.rosapiGraphError('$e'); loading = false; });
    }
  }

  @override
  void dispose() {
    _search.dispose();
    connection?.close();
    super.dispose();
  }

  void openTopic(String topic) => Navigator.push(context, MaterialPageRoute<void>(
    builder: (_) => TopicDetailPage(connection: connection!, topic: topic, type: topicTypes[topic] ?? '',
      onOpenNode: openNode)));

  void openNode(String node) => Navigator.push(context, MaterialPageRoute<void>(
    builder: (_) => NodeDetailPage(connection: connection!, node: node, onOpenTopic: openTopic,
      onOpenService: openService)));

  void openService(String service) => Navigator.push(context, MaterialPageRoute<void>(
    builder: (_) => ServiceDetailPage(connection: connection!, service: service)));

  @override
  Widget build(BuildContext context) {
    final q = _search.text.trim().toLowerCase();
    bool match(String s) => q.isEmpty || s.toLowerCase().contains(q);
    final topics = topicTypes.keys.where((t) => match(t) || match(topicTypes[t]!)).toList()..sort();
    final nodeItems = nodes.where(match).toList();
    final serviceItems = services.where(match).toList();
    return DefaultTabController(length: 3, child: Scaffold(
      appBar: AppBar(
        title: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(context.strings.rosExplorer, style: const TextStyle(fontWeight: FontWeight.w800))),
        actions: [
          IconButton(key: const Key('explorer-health'), tooltip: context.strings.topicHealth,
            icon: const Icon(Icons.monitor_heart_outlined),
            onPressed: loading || connection == null || topicTypes.isEmpty ? null : () => Navigator.push(context,
              MaterialPageRoute<void>(builder: (_) => TopicHealthPage(connection: connection!, topicTypes: topicTypes,
                remote: RelayAccess.isRelay(widget.ip))))),
          IconButton(key: const Key('explorer-refresh'), tooltip: context.strings.refresh,
          onPressed: loading ? null : refresh, icon: const Icon(Icons.refresh))],
        bottom: PreferredSize(preferredSize: const Size.fromHeight(112), child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: TextField(
            key: const Key('explorer-search'), controller: _search, onChanged: (_) => setState(() {}),
            decoration: InputDecoration(isDense: true, hintText: context.strings.searchNamesTypes,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: q.isEmpty ? null : IconButton(tooltip: context.strings.clear, icon: const Icon(Icons.close),
                onPressed: () => setState(_search.clear))),
          )),
          TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [
            Tab(text: '${context.strings.topics} ${loading ? '' : topics.length}'),
            Tab(text: '${context.strings.nodes} ${loading ? '' : nodeItems.length}'),
            Tab(text: '${context.strings.services} ${loading ? '' : serviceItems.length}'),
          ]),
        ])),
      ),
      body: errorMessage != null
          ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: StatusPanel(
              title: context.strings.rosExplorer, message: errorMessage!, isError: true, actionLabel: context.strings.retry, action: refresh))
          : loading
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(children: [
                  _list(topics, (t) => ListTile(
                    key: Key('topic-$t'),
                    leading: Icon(isHeavyType(topicTypes[t]) ? Icons.image_outlined : Icons.topic_outlined,
                      color: const Color(0xFF087F8C)),
                    title: Text(t), subtitle: Text(normalizeType(topicTypes[t]!)),
                    trailing: const Icon(Icons.chevron_right), onTap: () => openTopic(t))),
                  _list(nodeItems, (n) => ListTile(key: Key('node-$n'),
                    leading: const Icon(Icons.hub_outlined, color: Color(0xFF5365C6)), title: Text(n),
                    trailing: const Icon(Icons.chevron_right), onTap: () => openNode(n))),
                  _list(serviceItems, (s) => ListTile(key: Key('service-$s'),
                    leading: const Icon(Icons.call_made, color: Color(0xFF986334)), title: Text(s),
                    trailing: const Icon(Icons.chevron_right), onTap: () => openService(s))),
                ]),
    ));
  }

  Widget _list(List<String> items, Widget Function(String) tile) => items.isEmpty
      ? Center(child: Text(_search.text.isEmpty ? context.strings.nothingHereYet : context.strings.noMatches,
          style: TextStyle(color: context.muted)))
      : ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: items.length,
          separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
          itemBuilder: (_, i) => Material(color: context.card, child: tile(items[i])),
        );
}

/// Live view of one topic: who publishes and subscribes, the receive rate and the latest message.
class TopicDetailPage extends StatefulWidget {
  const TopicDetailPage({super.key, required this.connection, required this.topic, required this.type,
    this.onOpenNode});
  final RosConnection connection;
  final String topic;
  final String type;
  final void Function(String node)? onOpenNode;

  @override
  State<TopicDetailPage> createState() => TopicDetailPageState();
}

class TopicDetailPageState extends State<TopicDetailPage> with ThrottledRebuild {
  @override
  Duration get rebuildInterval => const Duration(milliseconds: 200);

  StreamSubscription? _sub;
  Timer? _ticker;
  List<String>? publishers, subscribers;
  Object? latest;
  int received = 0;
  bool paused = false;
  final _arrivals = <DateTime>[];
  late final bool heavy = isHeavyType(widget.type);

  double get rate {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 5));
    _arrivals.removeWhere((t) => t.isBefore(cutoff));
    return _arrivals.length / 5;
  }

  @override
  void initState() {
    super.initState();
    _sub = widget.connection.messages.listen((e) {
      if (e['op'] != 'publish' || e['topic'] != widget.topic || !mounted) return;
      _arrivals.add(DateTime.now());
      received++;
      if (paused) return; // the count and rate still refresh with the 1 s ticker
      latest = e['msg'];
      rebuildSoon(); // up to 50 messages/s arrive; formatting each one as JSON is wasted work
    });
    _subscribe();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    _loadEnds();
  }

  void _subscribe() {
    try {
      widget.connection.send({'op': 'subscribe', 'topic': widget.topic,
        // Light topics unthrottled (so the rate is real, up to 50 Hz); heavy ones once a second.
        'throttle_rate': heavy ? 1000 : 20, 'queue_length': 1});
    } catch (_) {}
  }

  Future<void> _loadEnds() async {
    Future<List<String>?> ask(String service, String key) async {
      try {
        return List<String>.from((await widget.connection.call(service, {'topic': widget.topic}))[key] as List? ?? []);
      } catch (_) { return null; }
    }
    final pubs = await ask('/rosapi/publishers', 'publishers');
    final subs = await ask('/rosapi/subscribers', 'subscribers');
    if (mounted) setState(() { publishers = pubs; subscribers = subs; });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _sub?.cancel();
    try { widget.connection.send({'op': 'unsubscribe', 'topic': widget.topic}); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = rate;
    final text = latest == null ? null : prettyJson(truncateForDisplay(latest));
    return Scaffold(
      appBar: AppBar(title: Text(widget.topic, overflow: TextOverflow.ellipsis), actions: [
        IconButton(key: const Key('topic-pause'), tooltip: paused ? 'Resume' : 'Pause',
          icon: Icon(paused ? Icons.play_arrow : Icons.pause), onPressed: () => setState(() => paused = !paused)),
        IconButton(key: const Key('topic-plot'), tooltip: context.strings.graphAValue,
          icon: const Icon(Icons.show_chart),
          onPressed: latest is! Map || numericFields(latest).isEmpty ? null : () async {
            final path = await pickPlotField(context, latest as Map);
            if (path == null || !context.mounted) return;
            Navigator.push(context, MaterialPageRoute(builder: (_) => PlotPage(connection: widget.connection,
              topic: widget.topic, fields: [pathField(path)], throttleMs: heavy ? 500 : 50)));
          }),
        IconButton(key: const Key('topic-copy'), tooltip: context.strings.copyAsJson,
          icon: const Icon(Icons.copy), onPressed: latest == null ? null : () {
            Clipboard.setData(ClipboardData(text: prettyJson(latest)));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.messageCopied)));
          }),
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        _card([
          _row(context.strings.typeLabel, normalizeType(widget.type)),
          _row(context.strings.rate, received == 0 ? context.strings.waitingMessages
              : heavy ? context.strings.heavyRate(r.toStringAsFixed(1))
              : '${r.toStringAsFixed(r < 10 ? 1 : 0)} Hz', key: const Key('topic-rate')),
          _row(context.strings.received, '$received'),
        ]),
        const SizedBox(height: 12),
        _card([
          _ends(context.strings.publishers, publishers),
          const SizedBox(height: 8),
          _ends(context.strings.subscribers, subscribers),
        ]),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xFF13202C), borderRadius: BorderRadius.circular(14)),
          child: text == null
              ? Text(context.strings.noMessageYet,
                  style: TextStyle(color: Colors.white70))
              : SelectableText(text, key: const Key('topic-message'),
                  style: const TextStyle(color: Color(0xFFD9F5EE), fontFamily: 'monospace', fontSize: 12)),
        ),
        if (paused) Padding(padding: EdgeInsets.only(top: 8),
          child: Text(context.strings.pausedFrozen,
            style: TextStyle(fontSize: 12, color: Colors.blueGrey))),
      ]),
    );
  }

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: context.card, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: context.border)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children));

  Widget _row(String label, String value, {Key? key}) => Padding(padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 92, child: Text(label, style: TextStyle(color: context.muted))),
      Expanded(child: SelectableText(value, key: key, style: const TextStyle(fontWeight: FontWeight.w600))),
    ]));

  Widget _ends(String label, List<String>? nodes) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(nodes == null ? '$label (unknown)' : '$label (${nodes.length})',
      style: TextStyle(color: context.muted)),
    if (nodes != null && nodes.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, children: [
      for (final n in nodes) ActionChip(label: Text(n), visualDensity: VisualDensity.compact,
        onPressed: widget.onOpenNode == null ? null : () => widget.onOpenNode!(n)),
    ]),
  ]);
}

/// What a node publishes, subscribes to and serves; every entry opens its own detail page.
class NodeDetailPage extends StatefulWidget {
  const NodeDetailPage({super.key, required this.connection, required this.node, this.onOpenTopic,
    this.onOpenService});
  final RosConnection connection;
  final String node;
  final void Function(String topic)? onOpenTopic;
  final void Function(String service)? onOpenService;

  @override
  State<NodeDetailPage> createState() => _NodeDetailPageState();
}

class _NodeDetailPageState extends State<NodeDetailPage> {
  Map<String, List<String>>? details;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // rosbridge's rosapi crashes (and stays down for every client) when asked about a node it does not
      // list: one that just stopped, or a hidden one (`_…`, e.g. the ros2 CLI daemon) seen as a publisher.
      // Ask only about nodes in its current list.
      final listed = (await widget.connection.call('/rosapi/nodes'))['nodes'];
      if (listed is List && !listed.contains(widget.node)) {
        if (mounted) setState(() => error = context.strings.nodeNotListed);
        return;
      }
      final v = await widget.connection.call('/rosapi/node_details', {'node': widget.node});
      if (!mounted) return;
      setState(() => details = {
        for (final k in ['publishing', 'subscribing', 'services']) k: List<String>.from(v[k] as List? ?? [])..sort(),
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = details;
    return Scaffold(
      appBar: AppBar(title: Text(widget.node, overflow: TextOverflow.ellipsis)),
      body: error != null
          ? Padding(padding: const EdgeInsets.all(16), child: StatusPanel(title: context.strings.nodeDetails,
              message: error!, isError: true, actionLabel: context.strings.retry, action: () { setState(() => error = null); _load(); }))
          : d == null ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.symmetric(vertical: 8), children: [
              _section(context.strings.publishes, d['publishing']!, Icons.north_east, widget.onOpenTopic),
              _section(context.strings.subscribesTo, d['subscribing']!, Icons.south_west, widget.onOpenTopic),
              _section(context.strings.services, d['services']!, Icons.call_made, widget.onOpenService),
            ]),
    );
  }

  Widget _section(String title, List<String> items, IconData icon, void Function(String)? open) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Text('${title.toUpperCase()} · ${items.length}', style: TextStyle(fontSize: 12, letterSpacing: 1.1,
            fontWeight: FontWeight.w700, color: context.muted))),
        if (items.isEmpty) Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(context.strings.none)),
        for (final i in items) Material(color: context.card, child: ListTile(dense: true, leading: Icon(icon, size: 18),
          title: Text(i), trailing: open == null ? null : const Icon(Icons.chevron_right, size: 18),
          onTap: open == null ? null : () => open(i))),
      ]);
}

/// Shows a service's type and request fields, and calls it with a JSON request.
class ServiceDetailPage extends StatefulWidget {
  const ServiceDetailPage({super.key, required this.connection, required this.service});
  final RosConnection connection;
  final String service;

  @override
  State<ServiceDetailPage> createState() => ServiceDetailPageState();
}

class ServiceDetailPageState extends State<ServiceDetailPage> {
  String? type;
  MessageSchema? request;
  final requestText = TextEditingController(text: '{}');
  bool calling = false;
  String? response;
  bool responseIsError = false;
  Duration? took;

  @override
  void initState() {
    super.initState();
    _describe();
  }

  Future<void> _describe() async {
    try {
      final t = '${(await widget.connection.call('/rosapi/service_type', {'service': widget.service}))['type'] ?? ''}';
      if (!mounted) return;
      setState(() => type = t);
      if (t.isEmpty) return;
      final details = await widget.connection.call('/rosapi/service_request_details', {'type': t});
      final defs = details['typedefs'];
      if (defs is List && defs.isNotEmpty && ((defs.first as Map)['fieldnames'] as List? ?? const []).isNotEmpty) {
        final schema = MessageSchema.fromRosapi(details);
        if (mounted) setState(() { request = schema; requestText.text = prettyJson(schema.defaults()); });
      }
    } catch (_) {
      // Type information is a convenience; the service can still be called with hand-written JSON.
    }
  }

  Future<void> call() async {
    Map<String, dynamic> args;
    try {
      final decoded = jsonDecode(requestText.text.trim().isEmpty ? '{}' : requestText.text);
      args = request == null ? Map<String, dynamic>.from(decoded as Map) : request!.coerce(decoded);
    } catch (e) {
      setState(() { response = context.strings.requestInvalid('$e'); responseIsError = true; });
      return;
    }
    setState(() { calling = true; response = null; });
    final started = DateTime.now();
    try {
      final values = await widget.connection.call(widget.service, args);
      if (!mounted) return;
      setState(() { response = prettyJson(truncateForDisplay(values)); responseIsError = false; });
    } catch (e) {
      if (mounted) setState(() { response = '$e'; responseIsError = true; });
    } finally {
      if (mounted) setState(() { calling = false; took = DateTime.now().difference(started); });
    }
  }

  @override
  void dispose() {
    requestText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.service, overflow: TextOverflow.ellipsis)),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(type == null ? context.strings.readingType : type!.isEmpty ? context.strings.typeUnknown : normalizeType(type!),
          key: const Key('service-type'), style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        TextField(key: const Key('service-request'), controller: requestText, minLines: 3, maxLines: 14,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          decoration: InputDecoration(labelText: context.strings.requestJson,
            helperText: request == null ? context.strings.noFieldsService
                : context.strings.prefilled(normalizeType(request!.root)),
            alignLabelWithHint: true)),
        const SizedBox(height: 12),
        Row(children: [
          FilledButton.icon(key: const Key('service-call'), onPressed: calling ? null : call,
            icon: calling ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.send, size: 18),
            label: Text(context.strings.callService)),
          const SizedBox(width: 12),
          if (took != null) Text('${took!.inMilliseconds} ms', style: TextStyle(color: context.muted)),
        ]),
        if (response != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: responseIsError ? context.cs.errorContainer : const Color(0xFF13202C),
              borderRadius: BorderRadius.circular(14)),
            child: SelectableText(response!, key: const Key('service-response'), style: TextStyle(
              fontFamily: 'monospace', fontSize: 12,
              color: responseIsError ? context.cs.onErrorContainer : const Color(0xFFD9F5EE))),
          ),
        ],
        const SizedBox(height: 8),
        Text(context.strings.callsActForReal,
          style: TextStyle(fontSize: 12, color: context.muted)),
      ]),
    );
  }
}
