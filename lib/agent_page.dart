import 'widgets/readable_width.dart';
import 'tool_tabs.dart';
import 'dart:async';
import 'app_language.dart';
import 'l10n/generated/app_localizations.dart';
import 'app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'agent/agent.dart';
import 'agent/audit_log.dart';
import 'agent/cloud_backend.dart';
import 'agent/local/llm.dart';
import 'agent/manifest.dart';
import 'agent/skill_labels.dart';
import 'agent/local/local_backend.dart';
import 'agent/router_backend.dart';
import 'robot_session.dart';

/// Where the assistant sends its planning requests (see tool/agent_proxy.py).
class AgentSettings {
  const AgentSettings({this.proxyUrl = '', this.token = '', this.onDeviceOnly = false});

  final String proxyUrl;
  final String token;
  /// Privacy mode: never send instructions or camera pictures off the phone; only the on-device model
  /// plans (no camera questions, no complex requests).
  final bool onDeviceOnly;

  /// Whether the online assistant may be used.
  bool get cloudConfigured => !onDeviceOnly && Uri.tryParse(proxyUrl)?.hasScheme == true;

  static const _urlKey = 'agent_proxy_url', _tokenKey = 'agent_proxy_token', _localKey = 'agent_on_device_only';

  static Future<AgentSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return AgentSettings(proxyUrl: prefs.getString(_urlKey) ?? '', token: prefs.getString(_tokenKey) ?? '',
          onDeviceOnly: prefs.getBool(_localKey) ?? false);
    } catch (_) {
      return const AgentSettings();
    }
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, proxyUrl);
    await prefs.setString(_tokenKey, token);
    await prefs.setBool(_localKey, onDeviceOnly);
  }
}

/// Type an instruction, the assistant plans it with a language model and the robot carries it out step
/// by step. Two models work as one assistant ([RouterBackend]): the on-device model (when downloaded)
/// for simple commands, the online one (Claude or Gemini through the proxy) for the rest, unless the
/// person chose on-device only.
/// Every step is listed as it happens; STOP (or typing "멈춰") halts the robot at once.
class AgentPage extends StatefulWidget {
  const AgentPage({super.key, required this.session, required this.log, this.backendFactory, this.localModel,
    this.extraActions = const []});

  final RobotSession session;
  /// Kept by the workspace, so the history survives leaving and reopening this page.
  final AuditLog log;
  /// For tests: builds the backend instead of the on-device and online models.
  final AgentBackend Function(AgentSettings settings)? backendFactory;
  /// For tests: the on-device model to use (null for none) instead of the downloaded one.
  final Future<LocalModel?> Function()? localModel;
  /// More buttons in the app bar (the saved routines, from the workspace).
  final List<Widget> extraActions;

  @override
  State<AgentPage> createState() => AgentPageState();
}

class AgentPageState extends State<AgentPage> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  AgentSettings? settings;
  RobotAgent? agent;
  NativeLlm? _llm;

  /// Shown before the robot's abilities are known.
  static const examples = ['Move forward 0.5 meters', 'Turn left 90 degrees', 'What are you doing?'];

  /// What this robot can do now (null until found out), for suggestions and the "can do" list.
  AgentManifest? manifest;

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_onLog);
    AgentSettings.load().then((s) {
      if (mounted) _use(s);
    });
  }

  Future<void> _use(AgentSettings s) async {
    AgentBackend? backend = widget.backendFactory?.call(s);
    if (backend == null) {
      LocalModel? model;
      if (widget.localModel != null) {
        model = await widget.localModel!();
      } else {
        final hasModel = NativeLlm.available && await LocalModelFile.exists();
        final path = hasModel ? await LocalModelFile.path() : null;
        if (!mounted) return;
        if (_llm?.modelPath != path) {
          await _llm?.dispose();
          _llm = path == null ? null : NativeLlm(path);
        }
        model = _llm;
      }
      final local = model == null ? null : LocalBackend(model);
      final cloud = s.cloudConfigured ? CloudBackend(endpoint: Uri.parse(s.proxyUrl), token: s.token) : null;
      if (local != null || cloud != null) backend = RouterBackend(local: local, cloud: cloud);
    }
    if (!mounted) return;
    agent?.removeListener(_onLog);
    agent?.dispose();
    setState(() {
      settings = s;
      agent = backend == null
          ? null
          : (RobotAgent.forSession(widget.session, backend, log: widget.log)..addListener(_onLog));
    });
    _learnAbilities();
  }

  /// Prepares the robot and finds out what it can do, so the suggestions fit it.
  Future<void> _learnAbilities() async {
    final a = agent;
    if (a == null) return;
    try {
      await a.prepare?.call();
      await a.tools?.refresh(force: true);
    } catch (_) {}
    if (mounted && identical(a, agent)) setState(() => manifest = a.manifest());
  }

  void _onLog() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    widget.log.removeListener(_onLog);
    agent?.removeListener(_onLog);
    agent?.dispose();
    _llm?.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> send([String? text]) async {
    final a = agent;
    final instruction = (text ?? _input.text).trim();
    if (a == null || instruction.isEmpty) return;
    if (a.busy && !RobotAgent.isStopWord(instruction)) return;
    _input.clear();
    await a.handle(instruction);
  }

  void stop() {
    final a = agent;
    if (a != null) {
      a.stop();
    } else {
      // Not set up yet: still stop whatever the session controllers are doing.
      widget.session.drive.stop();
      widget.session.nav.cancel();
    }
  }

  Future<void> openSettings() async {
    final result = await showDialog<AgentSettings>(context: context,
        builder: (_) => AgentSettingsDialog(initial: settings ?? const AgentSettings()));
    if (result == null || !mounted) return;
    try {
      await result.save();
    } catch (_) {}
    await _use(result);
  }

  @override
  Widget build(BuildContext context) {
    final a = agent;
    final entries = widget.log.entries;
    final compactTitle = MediaQuery.sizeOf(context).width < 360 &&
        MediaQuery.textScalerOf(context).scale(14) > 20;
    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: !(ToolTabsScope.maybeOf(context)?.split ?? false),
        // The robot's own name when it was given one (the assistant speaks as it); short enough for a phone
        // with large text beside STOP.
        title: Text(widget.session.memory.profile('name') ?? (compactTitle ? 'AI' : context.strings.assistant),
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w800)), actions: [
        // Always within reach, whatever the assistant is doing.
        Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: FilledButton(key: const Key('agent-stop'),
          onPressed: stop,
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white,
            minimumSize: const Size(0, 36), padding: const EdgeInsets.symmetric(horizontal: 14),
            textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800)),
          child: Text(context.strings.stop))),
        ...widget.extraActions,
        PopupMenuButton<String>(key: const Key('agent-menu'), tooltip: context.strings.more,
          onSelected: (v) => v == 'settings' ? openSettings() : widget.log.clear(),
          itemBuilder: (_) => [
            PopupMenuItem(key: const Key('agent-settings'), value: 'settings',
              child: ListTile(leading: const Icon(Icons.tune), title: Text(context.strings.assistantSettings))),
            PopupMenuItem(value: 'clear', enabled: entries.isNotEmpty && !(a?.busy ?? false),
              child: ListTile(leading: const Icon(Icons.delete_sweep_outlined), title: Text(context.strings.clearHistory))),
          ]),
      ]),
      body: ReadableWidth(maxWidth: 760, child: SafeArea(child: Column(children: [
        if (settings != null && a == null) _setupCard(),
        Expanded(child: entries.isEmpty
          ? _emptyState(a != null)
          : ListView.builder(controller: _scroll, padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              itemCount: entries.length, itemBuilder: (_, i) => _EntryView(entries[i]))),
        if (a?.busy ?? false) const LinearProgressIndicator(minHeight: 2),
        _inputBar(a),
      ]))),
    );
  }

  Widget _setupCard() => Card(margin: const EdgeInsets.all(16), child: Padding(padding: const EdgeInsets.all(16),
    // Text above the button: beside it, large text in a narrow column grows taller than the screen.
    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.cloud_off_outlined),
        const SizedBox(width: 12),
        Expanded(child: Text(settings?.onDeviceOnly ?? false ? context.strings.onDeviceStart : context.strings.needModelOrOnline)),
      ]),
      const SizedBox(height: 8),
      FilledButton(key: const Key('agent-setup'), onPressed: openSettings, child: Text(context.strings.setUp)),
    ])));

  Widget _emptyState(bool ready) => Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.smart_toy_outlined, size: 48, color: Color(0xFF5365C6)),
      const SizedBox(height: 12),
      Text(context.strings.tellRobot, textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 6),
      Text(context.strings.checksEachStep, textAlign: TextAlign.center, style: TextStyle(color: context.muted)),
      const SizedBox(height: 16),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        for (final (prompt, label) in _examples())
          if (MediaQuery.textScalerOf(context).scale(14) > 20)
            OutlinedButton(onPressed: ready ? () => send(prompt) : null, child: Text(label, textAlign: TextAlign.center))
          else
            ActionChip(label: Text(label), onPressed: ready ? () => send(prompt) : null),
      ]),
      if (manifest != null) ...[
        const SizedBox(height: 20),
        Text(context.strings.robotAbilities, style: TextStyle(fontWeight: FontWeight.w700, color: context.muted)),
        const SizedBox(height: 8),
        Wrap(key: const Key('agent-abilities'), spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
          for (final s in inEverydayOrder(manifest!.skills))
            if (s.name != 'stop' && s.name != 'cancel_navigation')
              Chip(visualDensity: VisualDensity.compact,
                avatar: Icon(skillLabel(s.name).icon, size: 16), label: Text(skillLabel(s.name).title)),
        ]),
      ],
    ])));

  Iterable<(String, String)> _examples() {
    final m = manifest;
    final l = context.strings;
    if (m == null) {
      return [(examples[0], l.exampleForward), (examples[1], l.exampleLeft), (examples[2], l.exampleStatus)];
    }
    // Translate what the button says while keeping the checked command the button sends.
    final labels = suggestionsFor(m, l);
    return suggestionsFor(m).indexed.map((entry) => (entry.$2, labels[entry.$1]));
  }

  /// One rounded field with the send button inside it, as chat apps have it. While the robot acts on
  /// an instruction the button turns into a red stop.
  Widget _inputBar(RobotAgent? a) {
    final busy = a?.busy ?? false;
    final hasText = _input.text.trim().isNotEmpty;
    return SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Container(
        decoration: BoxDecoration(color: context.card, borderRadius: BorderRadius.circular(28),
          border: Border.all(color: context.border),
          boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 2))]),
        padding: const EdgeInsets.fromLTRB(18, 4, 6, 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(child: TextField(key: const Key('agent-input'), controller: _input, enabled: a != null,
            textInputAction: TextInputAction.send, onSubmitted: (_) => send(), minLines: 1, maxLines: 4,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: a == null ? context.strings.setUpFirst : context.strings.tellRobot,
              hintMaxLines: 2,
              filled: false, border: InputBorder.none, enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none, disabledBorder: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 14)))),
          Padding(padding: const EdgeInsets.only(bottom: 4), child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            child: busy
                ? IconButton.filled(key: const Key('agent-halt'), tooltip: context.strings.stopRoutine, onPressed: stop,
                    style: IconButton.styleFrom(backgroundColor: const Color(0xFFD32F2F), foregroundColor: Colors.white),
                    icon: const Icon(Icons.stop_rounded))
                : IconButton.filled(key: const Key('agent-send'), tooltip: context.strings.send,
                    onPressed: a == null || !hasText ? null : send, icon: const Icon(Icons.arrow_upward_rounded)))),
        ]),
      )));
  }
}

class AgentSettingsDialog extends StatefulWidget {
  const AgentSettingsDialog({super.key, required this.initial});
  final AgentSettings initial;

  @override
  State<AgentSettingsDialog> createState() => AgentSettingsDialogState();
}

class AgentSettingsDialogState extends State<AgentSettingsDialog> {
  late final _url = TextEditingController(text: widget.initial.proxyUrl);
  late final _token = TextEditingController(text: widget.initial.token);
  late bool _onDeviceOnly = widget.initial.onDeviceOnly;
  bool? _hasModel;
  double? _progress; // while downloading
  String? _modelError;

  @override
  void initState() {
    super.initState();
    LocalModelFile.exists().then((v) {
      if (mounted) setState(() => _hasModel = v && NativeLlm.available);
    });
  }

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _modelError = null;
    });
    try {
      await LocalModelFile.download(onProgress: (got, total) {
        if (mounted) setState(() => _progress = total > 0 ? got / total : null);
      });
      if (mounted) setState(() => _hasModel = true);
    } catch (e) {
      if (mounted) setState(() => _modelError = '$e');
    } finally {
      if (mounted) setState(() => _progress = null);
    }
  }

  Widget _modelRow() {
    if (!NativeLlm.available) {
      return Text(context.strings.modelUnavailable);
    }
    final p = _progress;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        const Icon(Icons.memory, size: 20),
        const SizedBox(width: 8),
        Expanded(child: Text(_hasModel == true
            ? context.strings.modelReady
            : _onDeviceOnly
                ? context.strings.modelForPhone((LocalModelFile.sizeBytes / 1e9).toStringAsFixed(1))
                : context.strings.modelOptional((LocalModelFile.sizeBytes / 1e9).toStringAsFixed(1)))),
        if (_hasModel == false && p == null)
          TextButton(key: const Key('agent-model-download'), onPressed: _download, child: Text(context.strings.download)),
      ]),
      if (p != null) LinearProgressIndicator(value: p),
      if (_modelError != null) Text(_modelError!, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
    ]);
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  /// What the chosen setup can do now, in one line (or what is still missing).
  (bool, String) _readiness() {
    final model = _hasModel == true;
    final online = _url.text.trim().isNotEmpty && _token.text.trim().isNotEmpty;
    if (_onDeviceOnly) {
      return model
          ? (true, context.strings.readyPhone)
          : (false, context.strings.downloadToStart);
    }
    if (!online) return (false, context.strings.enterProxy);
    return (true, model ? context.strings.readyBoth : context.strings.readyOnline);
  }

  Widget _choice({required Key key, required bool selected, required IconData icon, required String title,
      required String subtitle, required VoidCallback onTap}) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      key: key,
      margin: const EdgeInsets.only(bottom: 8),
      color: selected ? cs.primaryContainer : null,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: selected ? cs.primary : cs.outlineVariant)),
      child: InkWell(borderRadius: BorderRadius.circular(14), onTap: onTap, child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: selected ? cs.onPrimaryContainer : null)),
            const SizedBox(height: 2),
            Text(subtitle, style: TextStyle(fontSize: 13, color: selected ? cs.onPrimaryContainer : cs.onSurfaceVariant)),
          ])),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: selected ? cs.primary : cs.outline),
        ]),
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final (ready, status) = _readiness();
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(context.strings.assistantSettings),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _choice(key: const Key('agent-mode-phone'), selected: _onDeviceOnly, icon: Icons.smartphone,
          title: context.strings.modePhone,
          subtitle: context.strings.modePhoneHint,
          onTap: () => setState(() => _onDeviceOnly = true)),
        _choice(key: const Key('agent-mode-online'), selected: !_onDeviceOnly, icon: Icons.cloud_outlined,
          title: context.strings.modeOnline,
          subtitle: context.strings.modeOnlineHint,
          onTap: () => setState(() => _onDeviceOnly = false)),
        const SizedBox(height: 8),
        if (_onDeviceOnly)
          _modelRow()
        else ...[
          TextField(key: const Key('agent-proxy-url'), controller: _url, keyboardType: TextInputType.url,
            autocorrect: false, onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.strings.proxyAddress,
              hintText: 'http://192.168.0.29:8787/v1/plan')),
          const SizedBox(height: 12),
          TextField(key: const Key('agent-proxy-token'), controller: _token, obscureText: true, autocorrect: false,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: context.strings.token)),
          const SizedBox(height: 12),
          // Optional: the phone model answers simple requests faster and without the network.
          _modelRow(),
        ],
        const SizedBox(height: 12),
        Row(key: const Key('agent-readiness'), children: [
          Icon(ready ? Icons.check_circle_outline : Icons.info_outline, size: 18,
            color: ready ? const Color(0xFF2E7D32) : cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(status, style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant))),
        ]),
      ])),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(key: const Key('agent-settings-save'),
          onPressed: _progress != null ? null : () => Navigator.pop(context, AgentSettings(
              proxyUrl: _url.text.trim(), token: _token.text.trim(), onDeviceOnly: _onDeviceOnly)),
          child: Text(context.strings.save)),
      ],
    );
  }
}

class _EntryView extends StatelessWidget {
  const _EntryView(this.entry);
  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    switch (entry.kind) {
      case AuditKind.instruction:
        return Align(alignment: Alignment.centerRight, child: _bubble(entry.text, const Color(0xFF182D42), Colors.white));
      case AuditKind.plan:
        return Align(alignment: Alignment.centerLeft, child: _bubble(entry.text, context.card, context.ink));
      case AuditKind.call:
        return _line(Icons.play_arrow, const Color(0xFF087F8C), entry.text, mono: true);
      case AuditKind.result:
        final line = entry.ok == false
            ? _line(Icons.error_outline, const Color(0xFFB3261E), entry.text)
            : _line(Icons.check_circle_outline, const Color(0xFF2E7D32), entry.text);
        final image = entry.image;
        if (image == null) return line;
        // What the camera showed the model (the `look` skill).
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          line,
          Padding(padding: const EdgeInsets.fromLTRB(30, 4, 0, 6), child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(image, key: const Key('agent-camera-image'), height: 140, fit: BoxFit.contain,
              gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()))),
        ]);
      case AuditKind.rejected:
        return _line(Icons.block, const Color(0xFFB3261E), entry.text);
      case AuditKind.note:
        return _line(Icons.info_outline, theme.colorScheme.onSurfaceVariant, entry.text);
    }
  }

  Widget _bubble(String text, Color background, Color foreground) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    constraints: const BoxConstraints(maxWidth: 520),
    decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(14),
      border: Border.all(color: foreground.withValues(alpha: 0.15))), // works on light and dark
    child: SelectableText(text, style: TextStyle(color: foreground, height: 1.4)));

  Widget _line(IconData icon, Color color, String text, {bool mono = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(fontSize: 13, color: color,
        fontFamily: mono ? 'monospace' : null))),
    ]));
}

/// Example instructions that this robot can carry out now (at most six), everyday ones first.
List<String> suggestionsFor(AgentManifest m, [AppLocalizations? l]) {
  bool has(String s) => m.skill(s) != null;
  return [
    if (has('move')) l?.exampleForward ?? 'Move forward 0.5 meters',
    if (has('rotate')) l?.exampleLeft ?? 'Turn left 90 degrees',
    if (has('go_to_place')) l?.exampleGo(m.places.first.name) ?? 'Go to ${m.places.first.name}',
    if (has('check_robot')) m.abilities?.battery != null
        ? l?.exampleBattery ?? 'How is the battery?' : l?.exampleProblem ?? 'Is anything wrong with the robot?',
    if (has('find_position')) l?.exampleLocation ?? 'Find where you are on the map',
    if (has('save_place')) l?.exampleSavePlace ?? 'Save this spot as "kitchen"',
    if (has('look')) l?.exampleLook ?? 'What do you see?',
    if (has('get_status')) l?.exampleStatus ?? 'What are you doing?',
  ].take(6).toList();
}
