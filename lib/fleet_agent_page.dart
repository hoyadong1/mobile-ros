import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'tool_tabs.dart';
import 'widgets/readable_width.dart';
import 'agent/agent.dart';
import 'agent/cloud_backend.dart';
import 'agent/fleet_agent.dart';
import 'agent/local/fleet_local_backend.dart';
import 'agent/local/llm.dart';
import 'agent/local/local_backend.dart';
import 'agent/router_backend.dart';
import 'agent_page.dart' show AgentSettings;
import 'robot_session.dart';
import 'routines.dart';

class FleetAgentPage extends StatefulWidget {
  const FleetAgentPage({super.key, required this.sessions});
  final List<RobotSession> sessions;

  @override
  State<FleetAgentPage> createState() => _FleetAgentPageState();
}

class _FleetAgentPageState extends State<FleetAgentPage> {
  final _input = TextEditingController();
  final _history = <String>[];
  FleetAgent? _agent;
  NativeLlm? _llm;
  /// Whether a model is set up for instructions in words (routines run either way).
  bool _talks = false;
  bool _busy = false;
  /// The fleet's own routines on this connection (each robot keeps its own on its screen).
  late final RoutineBook _routines = FleetAgent.bookFor(widget.sessions.first)..addListener(_changed);

  void _changed() { if (mounted) setState(() {}); }

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The same assistant as one robot's: the on-device model when it is downloaded, the online one when
  /// set up and allowed (not in on-device-only mode), one routing to the other.
  Future<void> _load() async {
    final settings = await AgentSettings.load();
    final hasModel = NativeLlm.available && await LocalModelFile.exists();
    final path = hasModel ? await LocalModelFile.path() : null;
    if (!mounted) return;
    if (_llm?.modelPath != path) {
      await _llm?.dispose();
      _llm = path == null ? null : NativeLlm(path);
    }
    if (!mounted) return;
    final local = _llm == null ? null : FleetLocalBackend(LocalBackend(_llm!));
    final cloud = settings.cloudConfigured
        ? CloudBackend(endpoint: Uri.parse(settings.proxyUrl), token: settings.token) : null;
    _agent?.dispose();
    _talks = local != null || cloud != null;
    // Saved routines need no model: without one the fleet still runs them (instructions are refused).
    setState(() => _agent = FleetAgent(widget.sessions,
        _talks ? RouterBackend(local: local, cloud: cloud) : RouterBackend(), routines: _routines));
    if (!_routines.loaded) await _routines.load();
  }

  Future<void> _configure() async {
    final current = await AgentSettings.load();
    if (!mounted) return;
    final saved = await showDialog<(String, String)>(context: context,
        builder: (_) => _ProxyDialog(url: current.proxyUrl, token: current.token));
    if (saved != null) {
      // Keeps the on-device-only choice: setting the address must not quietly send requests online.
      await AgentSettings(proxyUrl: saved.$1.trim(), token: saved.$2, onDeviceOnly: current.onDeviceOnly).save();
      await _load();
    }
  }

  Future<void> _send() async {
    final agent = _agent;
    final text = _input.text.trim();
    if (agent == null || !_talks || text.isEmpty || _busy) return;
    _input.clear();
    setState(() { _busy = true; _history.add(context.strings.youSaid(text)); });
    final AgentRun run = await agent.handle(text);
    if (!mounted) return;
    _show(run);
  }

  Future<void> _runRoutine(Routine routine) async {
    final agent = _agent;
    if (agent == null || _busy) return;
    setState(() { _busy = true; _history.add(context.strings.runRoutineLine(routine.name)); });
    final run = await agent.runRoutine(routine);
    if (!mounted) return;
    _show(run);
  }

  Future<void> _deleteRoutine(Routine routine) async {
    final yes = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: Text(context.strings.deleteQuestion(routine.name)),
      content: Text(context.strings.fleetRoutineDeleteDetail),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.strings.delete)),
      ],
    ));
    if (yes == true) await _routines.remove(routine.id);
  }

  void _show(AgentRun run) {
    setState(() {
      _history.addAll(run.replies);
      _history.addAll(run.results.map((r) => r.message));
      if (run.error case final error?) _history.add(error);
      _busy = false;
    });
  }

  @override
  void dispose() {
    _agent?.dispose();
    _llm?.dispose();
    _routines.removeListener(_changed);
    _routines.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        title: Text(ToolTabsScope.maybeOf(context)?.title ?? context.strings.fleetAssistant),
        bottom: ToolTabsScope.maybeOf(context)?.bar, actions: [
      IconButton(tooltip: context.strings.assistantConnection, icon: const Icon(Icons.tune), onPressed: _configure),
    ]),
    body: ReadableWidth(child: SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.all(16), child: Text(
        !_talks ? context.strings.fleetNoModel : context.strings.fleetHowTo)),
      if (_routines.routines.isNotEmpty) SizedBox(height: 48, child: ListView(
        scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
          for (final r in _routines.routines) Padding(padding: const EdgeInsets.only(right: 8), child: InputChip(
            key: Key('fleet-routine-${r.name}'),
            avatar: const Icon(Icons.play_arrow, size: 18),
            label: Text('${r.name} · ${{for (final s in r.steps) s.call?.args['robot']}.whereType<String>().join(', ')}'),
            tooltip: context.strings.runNamed(r.name),
            onPressed: _agent != null && !_busy ? () => _runRoutine(r) : null,
            onDeleted: () => _deleteRoutine(r),
          )),
        ])),
      Expanded(child: ListView(padding: const EdgeInsets.symmetric(horizontal: 16), children: [
        for (final line in _history) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(line)),
      ])),
      if (_busy) const LinearProgressIndicator(),
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: TextField(controller: _input, enabled: _talks && !_busy,
          decoration: InputDecoration(hintText: context.strings.fleetHint))),
        IconButton(tooltip: context.strings.send, onPressed: _talks && !_busy ? _send : null,
          icon: const Icon(Icons.send)),
        IconButton(tooltip: context.strings.stopAllRobots, onPressed: () {
          _agent?.stop();
          for (final session in widget.sessions) {
            session.drive.stop();
            session.nav.cancel();
          }
          setState(() => _history.add(context.strings.allRobotsStopped));
        }, icon: const Icon(Icons.stop)),
      ])),
    ])),
  ));
}

/// The online assistant's address and token; owns its text fields (they live through the closing animation).
class _ProxyDialog extends StatefulWidget {
  const _ProxyDialog({required this.url, required this.token});
  final String url, token;

  @override
  State<_ProxyDialog> createState() => _ProxyDialogState();
}

class _ProxyDialogState extends State<_ProxyDialog> {
  late final url = TextEditingController(text: widget.url);
  late final token = TextEditingController(text: widget.token);

  @override
  void dispose() {
    url.dispose();
    token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.strings.fleetConnectionTitle),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: url, decoration: InputDecoration(labelText: context.strings.proxyUrl)),
      TextField(controller: token, decoration: InputDecoration(labelText: context.strings.proxyToken), obscureText: true),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
      FilledButton(onPressed: () => Navigator.pop(context, (url.text, token.text)), child: Text(context.strings.save)),
    ],
  );
}
