import 'app_language.dart';
import 'dart:async';
import 'dart:convert';
import 'app_theme.dart';
import 'support_page.dart';
import 'robot_widget.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dds/direct.dart';
import 'foxglove_connection.dart';
import 'zenoh/zenoh.dart';
import 'main_page.dart';
import 'fleet_server_page.dart';
import 'message_definitions_page.dart';
import 'ros_connection.dart';
import 'widgets/status_panel.dart';
import 'relay_access.dart';
import 'cloud_robots_page.dart';

/// Account access is a development preview; the local stability release keeps its existing scope.
const cloudAccountsEnabled = bool.fromEnvironment('CLOUD_ACCOUNTS');

class ConnectPage extends StatefulWidget {
  const ConnectPage({super.key});

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  final _portController = TextEditingController(text: '9090');
  /// The access token for a robot reached through the relay (`wss://…/robots/<id>`).
  final _tokenController = TextEditingController();
  String? _tokenAddress;
  bool get _relay => mode == ConnectMode.rosbridge && RelayAccess.isRelay(_ipController.text);
  RosConnection? connection;
  bool isConnecting = false;
  String? errorMessage;
  List<RecentRobot> recentRobots = [];
  bool _showAllRecent = false;
  /// With saved robots the form for a new one stays folded until asked for.
  bool _addingRobot = false;
  int _attempt = 0;

  /// rosbridge: WebSocket to the robot's rosbridge. Direct: join the robot's ROS 2 network (DDS) as a
  /// node. Zenoh: a client of the robot's Zenoh router (robots on rmw_zenoh). Neither of the last two
  /// needs rosbridge.
  ConnectMode mode = ConnectMode.rosbridge;
  bool get direct => mode == ConnectMode.direct;
  bool get zenoh => mode == ConnectMode.zenoh;
  /// Direct and Zenoh use the second field for ROS_DOMAIN_ID instead of a port.
  bool get foxglove => mode == ConnectMode.foxglove;
  bool get _usesDomain => mode == ConnectMode.direct || mode == ConnectMode.zenoh;
  String _bridgePort = '9090', _domain = '0', _foxglovePort = '8765';
  DirectRosSession? _session;
  ZenohRosSession? _zenohSession;

  @override
  void initState() {
    super.initState();
    // A relay address shows the token field (and fills in the token saved for it).
    _ipController.addListener(() {
      if (!mounted) return;
      final address = _ipController.text.trim();
      if (address != _tokenAddress) {
        _tokenAddress = address;
        _tokenController.text = RelayAccess.isRelay(address) ? RelayAccess.tokenFor(address) ?? '' : '';
      }
      setState(() {});
    });
    _loadIpHistory().then((_) {
      // The widget's Connect opened the app: connect to the robot used last.
      if (RobotWidget.takePending() == 'connect') _connectFromWidget();
    });
    _widgetActions = RobotWidget.actions.listen((a) {
      if (a == 'connect') _connectFromWidget();
    });
  }

  StreamSubscription<String>? _widgetActions;

  void _connectFromWidget() {
    // Only from this screen: under a connected workspace the robot is already connected.
    if (!mounted || isConnecting || recentRobots.isEmpty || ModalRoute.of(context)?.isCurrent == false) return;
    _connectRecent(recentRobots.first);
  }

  Future<void> _loadIpHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        recentRobots = RecentRobot.load(prefs);
        _domain = prefs.getString('ros_domain_id') ?? '0';
        final saved = ConnectMode.values.asNameMap()[prefs.getString('connection_mode') ?? ''] ??
            ((prefs.getBool('direct_ros2') ?? false) ? ConnectMode.direct : ConnectMode.rosbridge);
        mode = saved.available ? saved : ConnectMode.rosbridge;
        if (_usesDomain) _portController.text = _domain;
        if (foxglove) _portController.text = _foxglovePort;
      });
    } catch (_) { /* Connection remains available if local history cannot be read. */ }
  }

  void _setMode(ConnectMode value) {
    if (value == mode) return;
    setState(() {
      if (_usesDomain) { _domain = _portController.text; } else if (foxglove) { _foxglovePort = _portController.text; }
      else { _bridgePort = _portController.text; }
      mode = value;
      _portController.text = _usesDomain ? _domain : foxglove ? _foxglovePort : _bridgePort;
      errorMessage = null;
    });
    SharedPreferences.getInstance().then((p) => p.setString('connection_mode', value.name)).catchError((_) => true);
  }

  /// Remembers how this robot was reached (mode, address, port or domain), newest first.
  Future<void> _saveRecent(String host, String portOrDomain) async {
    final prefs = await SharedPreferences.getInstance();
    await RecentRobot.save(prefs, RecentRobot(mode, host, portOrDomain));
    await _loadIpHistory();
  }

  /// One tap on a recent robot connects to it the way it was reached last time.
  /// The recent robot being connected to (its row shows the progress).
  RecentRobot? _connectingRecent;

  Future<void> _connectRecent(RecentRobot r) async {
    if (!r.mode.available) return;
    _setMode(r.mode);
    _ipController.text = r.host;
    _portController.text = r.portOrDomain;
    if (_relay && _tokenController.text.isEmpty) {
      setState(() => _addingRobot = true);
      return;
    }
    setState(() => _connectingRecent = r);
    try {
      await _connect();
    } finally {
      if (mounted) setState(() => _connectingRecent = null);
    }
  }

  Future<void> _forgetRecent(RecentRobot r) async {
    final prefs = await SharedPreferences.getInstance();
    await RecentRobot.remove(prefs, r);
    if (RelayAccess.isRelay(r.host)) await RelayAccess.save(r.host, '');
    await _loadIpHistory();
  }

  Future<void> _identifyRecent(RecentRobot r, String identity) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await RecentRobot.update(prefs, r, robotType: identity);
      if (mounted) setState(() => recentRobots = RecentRobot.load(prefs));
    } catch (_) { /* A history label must not interrupt a live robot connection. */ }
  }

  Future<void> _renameRecent(RecentRobot r) async {
    var edited = r.name;
    final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.nameRobot),
      content: TextFormField(key: const Key('recent-name'), initialValue: edited, autofocus: true,
        onChanged: (value) => edited = value,
        maxLength: 60, decoration: InputDecoration(labelText: context.strings.name, hintText: context.strings.nameExample,
          helperText: context.strings.nameHint, helperMaxLines: 3)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, edited.trim()), child: Text(context.strings.save))],
    ));
    if (name == null || !mounted) return;
    final prefs = await SharedPreferences.getInstance();
    await RecentRobot.update(prefs, r, name: name);
    if (mounted) setState(() => recentRobots = RecentRobot.load(prefs));
  }

  void _cancelConnection() {
    ++_attempt;
    connection?.close();
    connection = null;
    _session?.close();
    _session = null;
    _zenohSession?.close();
    _zenohSession = null;
    setState(() { isConnecting = false; errorMessage = null; });
  }

  Future<void> _connectZenoh() async {
    final attempt = _attempt;
    final router = _ipController.text.trim();
    final domain = int.parse(_portController.text.trim());
    ZenohRosSession? session;
    try {
      session = await ZenohRosSession.open(router: router, domain: domain);
      if (!mounted || attempt != _attempt) return;
      _zenohSession = session;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ros_domain_id', '$domain');
        await _saveRecent(router, '$domain');
      } catch (_) {}
      if (!mounted || attempt != _attempt) return;
      final live = session;
      _reconnectWanted = await Navigator.push<bool>(context, MaterialPageRoute<bool>(
        builder: (_) => MainPage(ip: router, port: '$domain', connection: live.connect(ownsSession: true),
          onRobotIdentified: (identity) => _identifyRecent(RecentRobot(ConnectMode.zenoh, router, '$domain'), identity),
          connectionFactory: (_, _) => live.connect(), address: 'Zenoh · $router · domain $domain'),
      ));
    } catch (error) {
      if (mounted && attempt == _attempt) {
        setState(() => errorMessage = error is UnsupportedError || error is StateError
          ? '${error is UnsupportedError ? error.message : (error as StateError).message}'
          : context.strings.zenohError(router));
      }
    } finally {
      session?.close();
      if (attempt == _attempt) {
        _zenohSession = null;
        if (mounted) setState(() => isConnecting = false);
      }
    }
  }

  Future<void> _connectDirect() async {
    final attempt = _attempt;
    final ip = _ipController.text.trim();
    final domain = int.parse(_portController.text.trim());
    DirectRosSession? session;
    try {
      session = await DirectRosSession.open(robot: ip, domain: domain);
      if (!mounted || attempt != _attempt) return;
      _session = session;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ros_domain_id', '$domain');
        await _saveRecent(ip, '$domain');
      } catch (_) {}
      if (!mounted || attempt != _attempt) return;
      final live = session;
      _reconnectWanted = await Navigator.push<bool>(context, MaterialPageRoute<bool>(
        builder: (_) => MainPage(ip: ip, port: '$domain', connection: live.connect(ownsSession: true),
          onRobotIdentified: (identity) => _identifyRecent(RecentRobot(ConnectMode.direct, ip, '$domain'), identity),
          connectionFactory: (_, _) => live.connect(),
          address: ip.isEmpty ? 'ROS 2 · domain $domain' : 'ROS 2 · $ip · domain $domain'),
      ));
    } catch (error) {
      if (mounted && attempt == _attempt) {
        setState(() => errorMessage = error is UnsupportedError ? '${error.message}'
          : context.strings.directError('$domain'));
      }
    } finally {
      session?.close();
      if (attempt == _attempt) {
        _session = null;
        if (mounted) setState(() => isConnecting = false);
      }
    }
  }

  /// foxglove_bridge: one WebSocket per screen, as with rosbridge; the definitions are loaded once.
  Future<void> _connectFoxglove() async {
    final attempt = _attempt;
    final host = _ipController.text.trim();
    final port = _portController.text.trim();
    RosConnection? candidate;
    try {
      final interfaces = await FoxgloveRosConnection.loadInterfaces();
      final client = FoxgloveRosConnection.open(host, port, interfaces);
      candidate = client;
      connection = client;
      await client.ready.timeout(const Duration(seconds: 8));
      if (!mounted || attempt != _attempt) return;
      try { await _saveRecent(host, port); } catch (_) {}
      if (!mounted || attempt != _attempt) return;
      _reconnectWanted = await Navigator.push<bool>(context, MaterialPageRoute<bool>(
        builder: (_) => MainPage(ip: host, port: port, connection: client,
          connectionFactory: (_, _) => FoxgloveRosConnection.open(host, port, interfaces),
          address: 'Foxglove · ${FoxgloveRosConnection.address(host, port).authority}',
          onRobotIdentified: (identity) => _identifyRecent(RecentRobot(ConnectMode.foxglove, host, port), identity)),
      ));
    } catch (_) {
      if (mounted && attempt == _attempt) setState(() => errorMessage = context.strings.foxgloveError('$host:$port'));
    } finally {
      if (attempt == _attempt) {
        candidate?.close();
        connection = null;
        if (mounted) setState(() => isConnecting = false);
      }
    }
  }

  /// Set when the workspace was left with "Reconnect": connect again with the same fields.
  bool? _reconnectWanted;

  Future<void> _connect() async {
    _reconnectWanted = null;
    await _connectOnce();
    if (_reconnectWanted == true && mounted) {
      _reconnectWanted = null;
      await _connect();
    }
  }

  Future<void> _connectOnce() async {
    if (isConnecting || !_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final attempt = ++_attempt;
    setState(() { isConnecting = true; errorMessage = null; });
    if (direct) return _connectDirect();
    if (zenoh) return _connectZenoh();
    if (foxglove) return _connectFoxglove();
    final ip = _ipController.text.trim();
    final port = _portController.text.trim();
    RosConnection? candidate;
    try {
      if (_relay) await RelayAccess.save(ip, _tokenController.text);
      final client = RosConnection(ip, port);
      candidate = client;
      connection = client;
      await client.ready;
      if (!mounted || attempt != _attempt) return;
      try { await _saveRecent(ip, port); } catch (_) {}
      if (!mounted || attempt != _attempt) return;
      _reconnectWanted = await Navigator.push<bool>(context, MaterialPageRoute<bool>(
        builder: (_) => MainPage(ip: ip, port: port, connection: client,
          address: _relay ? 'Remote · ${Uri.parse(ip).pathSegments.where((s) => s.isNotEmpty).last} · ${Uri.parse(ip).authority}' : null,
          onRobotIdentified: (identity) => _identifyRecent(RecentRobot(ConnectMode.rosbridge, ip, port), identity)),
      ));
    } catch (_) {
      if (mounted && attempt == _attempt) {
        setState(() => errorMessage =
          _relay ? context.strings.relayError
            : context.strings.rosbridgeError('$ip:$port'));
      }
    } finally {
      candidate?.close();
      if (attempt == _attempt) {
        connection = null;
        if (mounted) setState(() => isConnecting = false);
      }
    }
  }

  @override
  void dispose() {
    _widgetActions?.cancel();
    ++_attempt;
    connection?.close();
    _session?.close();
    _zenohSession?.close();
    _ipController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _showHelp() {
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text(context.strings.connectTitle),
      content: SingleChildScrollView(child: Text(context.strings.connectionHelp)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.gotIt))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mobile ROS', style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [PopupMenuButton<String>(key: const Key('app-menu'), tooltip: context.strings.menu,
          enabled: !isConnecting,
          onSelected: (v) {
            switch (v) {
              case 'appearance': chooseThemeMode(context);
              case 'language': _chooseLanguage();
              case 'guide': _showHelp();
              case 'fleet': Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const FleetServerConnectPage()));
              case 'messages': Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const MessageDefinitionsPage()));
              case 'support': Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SupportPage()));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'appearance', child: ListTile(leading: const Icon(Icons.brightness_6_outlined), title: Text(context.strings.appearance))),
            PopupMenuItem(value: 'language', key: const Key('app-language'),
              child: ListTile(leading: const Icon(Icons.language), title: Text(context.strings.language))),
            PopupMenuItem(value: 'guide', child: ListTile(leading: const Icon(Icons.help_outline), title: Text(context.strings.connectionGuide))),
            PopupMenuItem(value: 'fleet', child: ListTile(leading: const Icon(Icons.factory_outlined), title: Text(context.strings.fleetServer))),
            if (directRosSupported || zenohSupported)
              PopupMenuItem(value: 'messages', child: ListTile(leading: const Icon(Icons.data_object), title: Text(context.strings.messageDefinitions))),
            PopupMenuItem(value: 'support', child: ListTile(leading: const Icon(Icons.favorite_outline, color: Color(0xFFD81B60)), title: Text(context.strings.supportApp))),
          ])],
      ),
      body: SafeArea(child: Align(alignment: Alignment.topCenter, child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520),
          child: Form(key: _formKey, child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cloudAccountsEnabled) ...[
              OutlinedButton.icon(key: const Key('my-robots'),
                onPressed: isConnecting ? null : () => Navigator.push(context,
                  MaterialPageRoute<void>(builder: (_) => const CloudRobotsPage(fromLocal: true))),
                icon: const Icon(Icons.cloud_outlined), label: Text(context.strings.myRobots)),
              const SizedBox(height: 16),
              ],
              if (recentRobots.isEmpty) Row(children: [
                ClipRRect(borderRadius: BorderRadius.circular(12),
                  child: Image.asset('assets/app_icon.png', width: 44, height: 44, filterQuality: FilterQuality.medium)),
                const SizedBox(width: 14),
                Expanded(child: Text(context.strings.connectTitle, style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800, color: context.ink))),
              ]),
              if (errorMessage != null) ...[
                const SizedBox(height: 16),
                StatusPanel(title: context.strings.connectError, message: errorMessage!, isError: true),
              ],
              if (recentRobots.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final r in recentRobots.take(_showAllRecent ? RecentRobot.max : 3)) _recentTile(theme, r),
                if (recentRobots.length > 3) TextButton(
                  key: const Key('recent-expand'),
                  onPressed: () => setState(() => _showAllRecent = !_showAllRecent),
                  child: Text(_showAllRecent ? context.strings.showLess : context.strings.showAll(recentRobots.length))),
                if (!_addingRobot) Padding(padding: const EdgeInsets.only(top: 8), child: OutlinedButton.icon(
                  key: const Key('add-robot'), onPressed: isConnecting ? null : () => setState(() => _addingRobot = true),
                  icon: const Icon(Icons.add), label: Text(context.strings.addRobot))),
              ],
              AnimatedSize(duration: const Duration(milliseconds: 200), alignment: Alignment.topCenter,
                child: recentRobots.isNotEmpty && !_addingRobot ? const SizedBox(width: double.infinity)
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(height: recentRobots.isEmpty ? 24 : 16),
              ...[SegmentedButton<ConnectMode>(
                key: const Key('connection-mode'),
                direction: MediaQuery.textScalerOf(context).scale(14) > 19 &&
                    MediaQuery.sizeOf(context).width < 640 ? Axis.vertical : Axis.horizontal,
                segments: [
                  const ButtonSegment(value: ConnectMode.rosbridge, label: Text('rosbridge'), icon: Icon(Icons.cable)),
                  if (directRosSupported)
                    ButtonSegment(value: ConnectMode.direct, label: Text(context.strings.direct), icon: const Icon(Icons.hub_outlined)),
                  if (zenohSupported)
                    const ButtonSegment(value: ConnectMode.zenoh, label: Text('Zenoh'), icon: Icon(Icons.lan_outlined)),
                  const ButtonSegment(value: ConnectMode.foxglove, label: Text('Foxglove'), icon: Icon(Icons.podcasts)),
                ],
                selected: {mode},
                onSelectionChanged: isConnecting ? null : (v) => _setMode(v.first),
              ),
              const SizedBox(height: 16)],
              TextFormField(
                key: const Key('robot-host'), controller: _ipController, enabled: !isConnecting,
                autocorrect: false, enableSuggestions: false,
                keyboardType: TextInputType.url, textInputAction: TextInputAction.next,
                decoration: InputDecoration(
                  labelText: direct ? context.strings.robotIpOptional : context.strings.robotAddress,
                  hintText: direct ? context.strings.discoverOnWifi
                      : zenoh ? '192.168.1.100' : context.strings.addressExample,
                  errorMaxLines: 6, prefixIcon: const Icon(Icons.router_outlined)),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (direct) {
                    return text.isEmpty || !text.contains(RegExp(r'[\s:/?#@]')) ? null : context.strings.enterHost;
                  }
                  if (zenoh || foxglove) {
                    return text.isNotEmpty && !text.contains(RegExp(r'\s')) ? null : context.strings.enterRobotAddress;
                  }
                  try { robotUri(text, '9090'); return null; }
                  catch (_) { return context.strings.enterWebsocket; }
                },
              ),
              if (_relay) ...[
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('relay-token'), controller: _tokenController, enabled: !isConnecting,
                  obscureText: true, autocorrect: false, enableSuggestions: false,
                  decoration: InputDecoration(labelText: context.strings.accessToken,
                    helperText: context.strings.tokenHint,
                    helperMaxLines: 3, errorMaxLines: 3,
                    prefixIcon: const Icon(Icons.key_outlined)),
                  validator: (value) => RelayAccess.validToken(value ?? '') ? null : context.strings.enterToken,
                ),
              ],
              const SizedBox(height: 12),
              if (!_relay) TextFormField(
                key: const Key('robot-port'), controller: _portController, enabled: !isConnecting,
                keyboardType: TextInputType.number, textInputAction: TextInputAction.done,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(labelText: _usesDomain ? 'ROS_DOMAIN_ID' : context.strings.port,
                  prefixIcon: Icon(_usesDomain ? Icons.tag : Icons.settings_ethernet)),
                validator: (value) {
                  final number = int.tryParse(value ?? '');
                  if (_usesDomain) return number == null || number > 232 ? context.strings.enterDomain : null;
                  return number == null || number < 1 || number > 65535 ? context.strings.enterPort : null;
                },
                onFieldSubmitted: (_) => _connect(),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                key: const Key('connect-button'), onPressed: isConnecting ? null : _connect,
                icon: isConnecting ? const SizedBox(width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_forward),
                label: Text(isConnecting ? context.strings.connecting : context.strings.connect),
              ),
              if (recentRobots.isNotEmpty && !isConnecting) TextButton(
                onPressed: () => setState(() => _addingRobot = false), child: Text(context.strings.cancel)),
            ])),
              if (isConnecting) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: _cancelConnection, child: Text(context.strings.cancelConnection)),
              ],
            ],
          )),
        ),
      ))),
    );
  }

  Future<void> _chooseLanguage() async {
    final before = appLocale.value;
    await chooseAppLanguage(context);
    if (!mounted || before == appLocale.value) return;
    _formKey.currentState?.clearError();
    if (errorMessage != null) setState(() => errorMessage = null);
  }
}

extension on _ConnectPageState {
  Widget _recentTile(ThemeData theme, RecentRobot r) => Card(
    key: Key('recent-${r.mode.name}-${r.host}-${r.portOrDomain}'),
    margin: const EdgeInsets.only(bottom: 8),
    child: ListTile(
      enabled: !isConnecting && r.mode.available,
      leading: Icon(r.mode.icon, color: theme.colorScheme.primary),
      title: Text(r.title,
        style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(r.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () => _connectRecent(r),
      trailing: isConnecting && _connectingRecent?.same(r) == true
          ? const Padding(padding: EdgeInsets.all(12),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
          : PopupMenuButton<String>(tooltip: context.strings.robotOptions, enabled: !isConnecting,
              itemBuilder: (_) => [PopupMenuItem(value: 'rename', child: Text(context.strings.rename)),
                PopupMenuItem(value: 'forget', child: Text(context.strings.forget))],
              onSelected: (value) {
                if (value == 'rename') {
                  _renameRecent(r);
                } else {
                  _forgetRecent(r);
                }
              }),
    ),
  );
}

/// A robot connected to before, with everything needed to reach it again in one tap.
class RecentRobot {
  const RecentRobot(this.mode, this.host, this.portOrDomain, {this.name = '', this.robotType = ''});
  final ConnectMode mode;
  final String host;
  final String name, robotType;
  String get title => name.isNotEmpty ? name : robotType.isNotEmpty ? robotType
      : host.isEmpty ? 'Any robot on this Wi-Fi' : host;

  /// The rosbridge port, or the ROS_DOMAIN_ID for Direct and Zenoh.
  final String portOrDomain;

  static const _key = 'recent_robots';
  static const max = 5;

  /// One line under the name, without repeating it: the type (when named), the address (when it is
  /// not the title) and the connection.
  String get subtitle => [
    if (name.isNotEmpty && robotType.isNotEmpty && robotType != name) robotType,
    if (host.isNotEmpty && host != title) host,
    switch (mode) {
      ConnectMode.rosbridge => portOrDomain == '9090' ? 'rosbridge' : 'rosbridge :$portOrDomain',
      ConnectMode.direct => portOrDomain == '0' ? 'Direct' : 'Direct · domain $portOrDomain',
      ConnectMode.zenoh => portOrDomain == '0' ? 'Zenoh' : 'Zenoh · domain $portOrDomain',
      ConnectMode.foxglove => portOrDomain == '8765' ? 'Foxglove' : 'Foxglove :$portOrDomain',
    },
  ].join(' · ');

  String get description => switch (mode) {
    ConnectMode.rosbridge => 'rosbridge · port $portOrDomain',
    ConnectMode.direct => 'Direct ROS 2 · domain $portOrDomain',
    ConnectMode.zenoh => 'Zenoh · domain $portOrDomain',
    ConnectMode.foxglove => 'Foxglove bridge · port $portOrDomain',
  };

  Map<String, String> toJson() => {'mode': mode.name, 'host': host, 'port': portOrDomain,
    'name': name, 'robotType': robotType};

  bool same(RecentRobot o) => o.mode == mode && o.host == host && o.portOrDomain == portOrDomain;

  /// Newest first. Older versions kept bare rosbridge addresses under robot_ip_history.
  static List<RecentRobot> load(SharedPreferences prefs) {
    final saved = prefs.getStringList(_key);
    if (saved != null) {
      return [for (final e in saved) ?_parse(e)].take(max).toList();
    }
    return [for (final ip in prefs.getStringList('robot_ip_history') ?? const <String>[]) RecentRobot(ConnectMode.rosbridge, ip, '9090')].take(max).toList();
  }

  static RecentRobot? _parse(String e) {
    try {
      final m = jsonDecode(e) as Map;
      final mode = ConnectMode.values.asNameMap()['${m['mode']}'];
      return mode == null ? null : RecentRobot(mode, '${m['host'] ?? ''}', '${m['port'] ?? ''}',
        name: '${m['name'] ?? ''}', robotType: '${m['robotType'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(SharedPreferences prefs, RecentRobot r) async {
    final list = load(prefs);
    final previous = list.where(r.same).firstOrNull;
    list.removeWhere(r.same);
    list.insert(0, RecentRobot(r.mode, r.host, r.portOrDomain,
      name: r.name.isNotEmpty ? r.name : previous?.name ?? '',
      robotType: r.robotType.isNotEmpty ? r.robotType : previous?.robotType ?? ''));
    await prefs.setStringList(_key, [for (final x in list.take(max)) jsonEncode(x.toJson())]);
  }

  static Future<void> remove(SharedPreferences prefs, RecentRobot r) async {
    final list = load(prefs)..removeWhere(r.same);
    await prefs.setStringList(_key, [for (final x in list) jsonEncode(x.toJson())]);
  }

  /// Updates a saved endpoint in place; late discovery must not resurrect a forgotten robot.
  static Future<void> update(SharedPreferences prefs, RecentRobot r, {String? name, String? robotType}) async {
    final list = load(prefs);
    final index = list.indexWhere(r.same);
    if (index < 0) return;
    final old = list[index];
    list[index] = RecentRobot(old.mode, old.host, old.portOrDomain,
      name: name ?? old.name, robotType: robotType ?? old.robotType);
    await prefs.setStringList(_key, [for (final x in list) jsonEncode(x.toJson())]);
  }
}

/// How the app reaches the robot.
enum ConnectMode {
  rosbridge,
  direct,
  zenoh,
  foxglove;

  /// One line under the mode switch: what the robot needs for this mode.
  String get explanation => switch (this) {
    ConnectMode.rosbridge => 'The robot runs rosbridge (WebSocket, port 9090). Works with ROS 1 and ROS 2.',
    ConnectMode.direct => 'Nothing to install on the robot: this phone joins its ROS 2 network. Same Wi-Fi as the robot.',
    ConnectMode.zenoh => 'For ROS 2 robots on rmw_zenoh: connects to the robot\'s Zenoh router (port 7447).',
    ConnectMode.foxglove => 'For ROS 2 robots running foxglove_bridge (WebSocket, port 8765). No rosbridge needed.',
  };

  IconData get icon => switch (this) {
    ConnectMode.rosbridge => Icons.cable,
    ConnectMode.direct => Icons.hub_outlined,
    ConnectMode.zenoh => Icons.lan_outlined,
    ConnectMode.foxglove => Icons.podcasts,
  };

  /// Whether this build supports the mode (the web has rosbridge only).
  bool get available => switch (this) {
    ConnectMode.rosbridge => true,
    ConnectMode.direct => directRosSupported,
    ConnectMode.zenoh => zenohSupported,
    ConnectMode.foxglove => true,
  };
}
