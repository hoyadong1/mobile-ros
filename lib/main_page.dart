import 'app_language.dart';
import 'memory.dart';
import 'robot_identity.dart';
import 'robot_memory_page.dart';
import 'robot_persona.dart';
import 'widgets/robot_intro.dart';
import 'map_geometry.dart' show Pose2D;
import 'places.dart' show whereIs;
import 'dart:typed_data';
import 'dart:async';
import 'app_theme.dart';
import 'package:material_ui/material_ui.dart';
import 'ros_connection.dart';
import 'control_page.dart';
import 'disconnect_safety.dart';
import 'explorer_page.dart';
import 'publish_page.dart';
import 'map_page.dart';
import 'robot_capabilities.dart';
import 'robot_session.dart';
import 'agent/agent.dart';
import 'agent/audit_log.dart';
import 'routine_scheduler.dart';
import 'background_service.dart';
import 'robot_widget.dart';
import 'mini_map.dart';
import 'controllers/navigation_controller.dart' show NavStatus;
import 'status_page.dart';
import 'assistant_page.dart';
import 'fleet_page.dart';
import 'foxglove_connection.dart';
import 'diagnostics.dart';
import 'incident_recorder.dart';
import 'incidents_page.dart';
import 'nav_progress.dart';
import 'robot_log.dart' show LogLevel;
import 'robot_requests.dart';
import 'sensors.dart';
import 'robot_summary.dart';
import 'routines.dart';
import 'agent/skill_labels.dart' show describeCall;
import 'routines_page.dart';
import 'dds/direct.dart';
import 'message_definitions_page.dart';
import 'params_page.dart';
import 'system_notifier.dart';
import 'widgets/help_request_dialog.dart';
import 'widgets/robot_summary_card.dart';
import 'zenoh/zenoh.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'connect_page.dart' show cloudAccountsEnabled;
import 'cloud_session.dart' show CloudRosConnection;
import 'remote_setup_page.dart';

class MainPage extends StatefulWidget {
  const MainPage({super.key, required this.ip, required this.port, required this.connection,
      this.connectionFactory = RosConnection.new, this.address, this.presence, this.onRobotIdentified});
  final ValueChanged<String>? onRobotIdentified;
  final String ip;
  final String port;
  final RosConnection connection;

  /// How each tool opens its own connection: a new rosbridge socket, or a view on the direct session.
  final RosConnection Function(String, String) connectionFactory;

  /// Shown instead of "ip:port" (e.g. for a direct ROS 2 connection).
  final String? address;

  /// The background notification (a foreground service on Android); tests pass a fake.
  final BackgroundPresence? presence;

  @override
  State<MainPage> createState() => _MainPageState();
}

/// One robot on the connection and what the workspace keeps for it: its session (controllers, places,
/// routines, questions), the assistant's history, and the routine runner with its schedule.
class _Robot {
  _Robot(this.session, void Function(_Robot robot, String message) report) {
    routineAgent = RobotAgent.forSession(session, NoPlanner(), log: log)..describeStep = describeCall;
    scheduler = RoutineScheduler(session.routines, run: (routine) async {
      report(this, appStrings.routineStartingNotice(routine.name, session.name));
      final run = await routineAgent.runRoutine(routine, source: 'schedule');
      if (run.error != null || !run.ok) {
        final message = appStrings.routineFailedNotice(routine.name,
            run.error ?? run.results.lastOrNull?.message ?? appStrings.failed);
        report(this, message);
        // Schedules run with nobody looking: a failure must reach the person outside the app too.
        if (!_disposed) {
          session.requests.add(RobotNotice(session.name, message, NoticeLevel.error));
          saveIncident(appStrings.reasonRoutineFailed);
        }
      }
    });
  }

  final RobotSession session;
  /// The robot's battery as shown ("80 %"), read every 10 s when it reports one; '' otherwise.
  String battery = '';
  StreamSubscription<Map<String, dynamic>>? _battery;
  /// Low battery was announced; again only after it has recovered (charging or above the threshold).
  bool _lowBatteryAnnounced = false;
  /// A trip that stopped getting closer to its goal: announced once per goal.
  final _progress = NavProgressWatch();
  Timer? _progressTimer;

  /// The last 5 minutes, saved as a record when something goes wrong (see incident_recorder.dart).
  final recorder = IncidentRecorder();
  static final incidents = IncidentStore();
  Timer? _poseTimer;
  StreamSubscription<RobotNotice>? _noticeWatch;
  String _lastDrive = '';
  NavStatus? _lastNav;
  int _auditSeen = 0;
  /// Log lines already looked at, by identity: the robot's clock (sim time, another zone) cannot be
  /// compared with the phone's. Lines present when recording starts are not news.
  final _logSeen = Expando<bool>();
  bool _logPrimed = false;

  Future<Incident?> saveIncident(String reason) async {
    try {
      return await incidents.save(recorder.snapshot(session.name, reason));
    } catch (_) {
      return null; // a record is a help, never a reason to fail
    }
  }

  void _recordDrive() {
    final c = session.drive.current;
    final text = c.isStop ? 'stop' : '${session.drive.source?.name ?? 'other'}: '
        '${c.linearX.toStringAsFixed(2)} m/s, ${c.angularZ.toStringAsFixed(2)} rad/s'
        '${c.linearY == 0 ? '' : ', side ${c.linearY.toStringAsFixed(2)} m/s'}';
    if (text == _lastDrive) return;
    _lastDrive = text;
    recorder.record(IncidentKind.command, text);
  }

  void _recordNav() {
    final nav = session.nav;
    if (nav.status == _lastNav) return;
    _lastNav = nav.status;
    final left = nav.distanceRemaining;
    recorder.record(IncidentKind.nav, '${nav.status.name}${left == null ? '' : ' (${left.toStringAsFixed(1)} m left)'}',
        level: nav.status == NavStatus.failed ? 'error' : null);
    if (nav.status == NavStatus.failed) saveIncident(appStrings.reasonNavFailed);
  }

  void _recordLog() {
    for (final e in session.robotLog.entries) {
      if (_logSeen[e] == true) continue;
      _logSeen[e] = true;
      if (!_logPrimed || e.level.index < LogLevel.warn.index) continue;
      recorder.record(IncidentKind.log, '${e.node}: ${e.text}', level: e.level.index >= LogLevel.error.index ? 'error' : 'warning');
    }
    _logPrimed = true;
  }

  void _recordAssistant() {
    final entries = log.entries;
    if (entries.length < _auditSeen) _auditSeen = 0; // cleared
    for (final e in entries.skip(_auditSeen)) {
      recorder.record(IncidentKind.ai, '${e.kind.name}: ${e.text}', level: e.ok == false ? 'warning' : null);
    }
    _auditSeen = entries.length;
  }
  bool _disposed = false;

  /// Follows the battery for the notification and widget (slowly: a reading every 10 s).
  Future<void> watchBattery(void Function() changed) async {
    try {
      final caps = await session.capabilities();
      if (_disposed) return;
      final topic = caps.topicsOfType('sensor_msgs/BatteryState').firstOrNull;
      if (topic == null) return;
      _battery = session.ros.subscribe(topic, throttleRate: 10000).listen((msg) {
        final s = decodeSensor(SensorKind.battery, msg);
        final pct = RegExp(r'\d+ ?%').firstMatch(s.headline)?.group(0) ?? s.headline;
        // Once per discharge, as robot fleet apps alert on low battery: not every 10 s reading.
        if (s.warning != null && !_lowBatteryAnnounced && !_disposed) {
          _lowBatteryAnnounced = true;
          session.requests.add(RobotNotice(session.name, appStrings.batteryLowNotice(pct), NoticeLevel.warning));
        } else if (s.warning == null) {
          _lowBatteryAnnounced = false;
        }
        if (pct != battery) {
          battery = pct;
          changed();
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  StreamSubscription<Map<String, dynamic>>? _diagnostics;
  final _diagAlerts = DiagnosticsAlerts();
  final _diagLevels = <String, DiagLevel>{};

  /// Follows the robot's own health reports (/diagnostics): a part that turns to ERROR is a notice (once,
  /// again only after it was OK), every change of level goes into the incident record.
  Future<void> watchDiagnostics() async {
    try {
      final caps = await session.capabilities();
      if (_disposed) return;
      final all = caps.topicsOfType('diagnostic_msgs/DiagnosticArray');
      // A robot in a namespace reads its own; a shared /diagnostics is only its own when it is alone.
      final ns = session.namespace;
      final own = ns.isEmpty || ns == '/' ? all : all.where((t) => t.startsWith('$ns/')).toList();
      final mine = own.isNotEmpty ? own : caps.sharesNetwork ? const <String>[] : all;
      final topics = {for (final t in mine) t: 'diagnostic_msgs/DiagnosticArray'};
      final topic = pickDiagnosticsTopic(topics);
      if (topic == null) return;
      final board = DiagnosticsBoard();
      _diagnostics = session.ros.subscribe(topic, throttleRate: 1000).listen((msg) {
        if (_disposed) return;
        final reports = board.update(msg, DateTime.now());
        for (final r in reports) {
          if (_diagLevels[r.name] == r.level) continue;
          final before = _diagLevels[r.name];
          _diagLevels[r.name] = r.level;
          if (before == null && r.level == DiagLevel.ok) continue; // fine from the start: not news
          recorder.record(IncidentKind.log, 'diagnostics ${r.name}: ${r.level.name.toUpperCase()} ${r.message}'.trim(),
              level: switch (r.level) { DiagLevel.error => 'error', DiagLevel.warn || DiagLevel.stale => 'warning', _ => null });
        }
        final fresh = _diagAlerts.newErrors(reports);
        if (fresh.isEmpty) return;
        final first = fresh.first;
        session.requests.add(RobotNotice(session.name, fresh.length == 1
            ? appStrings.diagErrorNotice(first.shortName, first.message)
            : appStrings.diagErrorsNotice(fresh.length, fresh.map((f) => f.shortName).take(3).join(', ')),
            NoticeLevel.error));
      }, onError: (_) {});
    } catch (_) {}
  }

  /// The assistant's history for this robot, kept while the workspace is open.
  final log = AuditLog();
  /// Runs saved routines (from the routines screen and on schedule), logged with the assistant's history.
  late final RobotAgent routineAgent;
  late final RoutineScheduler scheduler;

  void start(SystemRobotNotifier? notifier) {
    if (notifier != null) session.requests.notifier = notifier;
    _poseTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      final p = session.odometry.pose;
      if (p != null && session.odometry.isFresh(maxAge: const Duration(seconds: 2))) recorder.pose(p.x, p.y);
    });
    session.drive.addListener(_recordDrive);
    session.nav.addListener(_recordNav);
    _recordLog(); // what is already there is not news
    session.robotLog.addListener(_recordLog);
    log.addListener(_recordAssistant);
    _noticeWatch = session.requests.noticeStream.listen((n) =>
        recorder.record(IncidentKind.notice, '${n.title}: ${n.message}', level: n.level == NoticeLevel.info ? null : n.level.name));
    // Every 5 s, whoever sent the goal (map screen, assistant, routine): a stuck trip reaches the person.
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final nav = session.nav;
      final left = nav.isActive ? nav.distanceRemaining : null;
      if (_progress.update(left, DateTime.now(), goal: nav.goalCount) && !_disposed) {
        session.requests.add(RobotNotice(session.name,
            appStrings.navStuckNotice('${left!.toStringAsFixed(1)} m'), NoticeLevel.warning));
        saveIncident(appStrings.reasonStuck);
      }
    });
    session.routines.load().then((_) { if (!_disposed) scheduler.start(); });
    session.robotLog.start();
  }

  void dispose() {
    _disposed = true;
    _battery?.cancel();
    _diagnostics?.cancel();
    _progressTimer?.cancel();
    _poseTimer?.cancel();
    _noticeWatch?.cancel();
    session.drive.removeListener(_recordDrive);
    session.nav.removeListener(_recordNav);
    session.robotLog.removeListener(_recordLog);
    log.removeListener(_recordAssistant);
    scheduler.dispose();
    session.drive.automation.interrupt();
    routineAgent.stop();
    routineAgent.dispose();
    log.dispose();
    session.dispose(); // stops the base before the connection goes
  }
}

class _MainPageState extends State<MainPage> {
  StreamSubscription? _connectionSubscription;

  /// The robots on this connection: one at the root, or one per namespace (`/robot1`, `/robot2`) when
  /// discovery finds several. Starts with the root robot and is replaced once discovery has answered.
  List<_Robot> robots = [];
  int active = 0;
  /// What the robot turned out to be ("TurtleBot3", "2 robots"), the screen's title once known.
  String? robotLabel;

  /// The robot computer's address for SSH: the host of the address this connection uses.
  String _computerHost() {
    final ip = widget.ip.trim();
    final host = ip.contains('://') ? (Uri.tryParse(ip)?.host ?? '') : ip;
    return host == '127.0.0.1' || host == 'localhost' ? '' : host;
  }
  final _homeMapKeys = <String, GlobalKey<MiniMapState>>{};
  SystemRobotNotifier? _notifier;
  BackgroundPresence? _presence;
  StreamSubscription<String>? _presenceActions, _widgetActions;
  final Future<bool> _canPinWidget = RobotWidget.canPin();
  Timer? _presenceTimer;
  bool _closing = false;
  int _presenceVersion = 0;
  /// When the last running routine ended. The widget shows Run where Stop was, so a Stop tapped just as a
  /// routine finished lands on Run: such a Run is ignored instead of starting the robot again.
  DateTime? _routineEndedAt;
  bool _routineWasRunning = false;
  static const _runGuard = Duration(seconds: 3);

  /// Keeps the background notification in line with the robots: a running routine (progress, Stop) or
  /// the next scheduled one (so it runs with the app in the background), else none.
  void _updatePresence() {
    // A workspace that closed (robots disposing notify their listeners) must not touch the notification.
    if (!mounted || _closing) return;
    final version = ++_presenceVersion;
    final p = _presence;
    final online = !widget.connection.isClosed;
    final s = context.strings;
    String detail(RoutineProgress r) => '${r.roundText(s)} · ${r.waitingUntil != null
        ? s.nextRound(secondsLeft(r.waitingUntil!))
        : r.steps == 0 ? s.starting : '${r.doing} (${r.step}/${r.steps})'}';
    final running = [
      for (final r in robots)
        if (r.routineAgent.progress case final pr?) (robots.length > 1 ? r.session.name : '', pr.routine, detail(pr)),
    ];
    if (_routineWasRunning && running.isEmpty) _routineEndedAt = DateTime.now();
    _routineWasRunning = running.isNotEmpty;
    (String, String, DateTime)? next;
    if (online) {
      for (final r in robots) {
        final n = r.scheduler.next();
        if (n != null && (next == null || n.$2.isBefore(next.$3))) next = (r.session.name, n.$1.name, n.$2);
      }
    }
    final battery = robots.map((r) => r.battery).firstWhere((b) => b.isNotEmpty, orElse: () => '');
    final name = robotLabel ?? widget.address ?? '${widget.ip}:${widget.port}';
    final want = presenceFor(running: running, next: next, now: DateTime.now(),
        connectedTo: online ? name : null, battery: battery, strings: s);
    // The home screen widget says the same as the notification, with the battery and a Run button.
    if (want == null) {
      RobotWidget.disconnected();
    } else {
      _widgetRoutine().then<void>((routine) async {
        if (!mounted || _closing || version != _presenceVersion) return;
        // The widget: the robot's name and battery on top, what it does (large) and the detail under it.
        final (status, detail) = running.isEmpty
            ? (s.connected, next == null ? s.widgetReady : want.text)
            : running.length == 1 ? (s.runningNamed(running.first.$2), running.first.$3) : (want.title, want.text);
        await RobotWidget.show(title: name, text: status, detail: detail, where: _where,
          problems: robots.fold<int>(0, (n, r) => n + r.session.robotLog.unseenProblems),
          connected: true, battery: battery, running: running.isNotEmpty,
          routineId: online ? routine?.id ?? '' : '', routineName: online ? routine?.name ?? '' : '');
      });
    }
    if (want == null) {
      p?.hide();
    } else {
      p?.show(title: want.title, text: want.text, stoppable: want.stoppable);
    }
  }

  /// Where the robot is, for the widget ("At kitchen", or coordinates), from the home screen's map.
  String _where = '';

  void _onMapSnapshot(Uint8List png, Pose2D robot) {
    RobotWidget.saveMap(png);
    final where = whereIs(robot, session.places.usable);
    if (where != _where) {
      _where = where;
      _updatePresence();
    }
  }

  /// The routine the widget's Run button starts: the one run last, else the first saved one.
  Future<Routine?> _widgetRoutine() async {
    final id = await RobotWidget.rememberedRoutine();
    for (final r in robots) {
      final found = id == null ? null : r.session.routines.byId(id);
      if (found != null) return found;
    }
    return robots.expand((r) => r.session.routines.routines).firstOrNull;
  }

  /// `run:ID` from the widget: runs that routine on the robot that has it.
  Future<void> _runFromWidget(String id) async {
    if (_closing || !mounted || id.isEmpty) return;
    final ended = _routineEndedAt;
    if (ended != null && DateTime.now().difference(ended) < _runGuard) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.routineJustEnded)));
      return;
    }
    if (widget.connection.isClosed) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.strings.reconnectRoutine)));
      return;
    }
    for (final r in robots) {
      if (!r.session.routines.loaded) await r.session.routines.load();
      if (_closing || !mounted || widget.connection.isClosed || !robots.contains(r)) return;
      final routine = r.session.routines.byId(id);
      if (routine == null) continue;
      if (r.routineAgent.busy) {
        if (mounted) _report(r, context.strings.routineAlreadyRunning);
        return;
      }
      if (mounted) _report(r, context.strings.routineStartingFromWidget(routine.name));
      await r.routineAgent.runRoutine(routine, source: 'widget');
      return;
    }
  }

  void _watchRobot(_Robot r) {
    r.routineAgent.addListener(_updatePresence);
    r.session.routines.addListener(_updatePresence);
  }

  /// The robot the tools work on.
  RobotSession get session => robots[active].session;

  /// This connection's address, and the saved robot it belongs to (see [RobotIdentity]).
  String get _address => '${widget.ip}:${widget.port}';
  late String _storeKey = _address;

  /// Finds which saved robot this is: the one this address was linked to, or, when the robot looks like one
  /// seen at another address (same ROS nodes), the one the person confirms. Returns the store key.
  Future<String> _identify(RobotCapabilities caps, String label) async {
    final identity = await RobotIdentity.load();
    var key = identity.storeKeyFor(_address);
    final fingerprint = RobotIdentity.fingerprint(caps.nodes);
    final match = key == _address ? identity.match(fingerprint, _address) : null;
    if (match != null && mounted) {
      final known = Memory(Memory.robotScope(match.storeKey));
      await known.load();
      final name = known.profile(RobotPersona.nameKey) ?? (match.label.isEmpty ? 'a robot' : match.label);
      if (!mounted) return key;
      final same = await showDialog<bool>(context: context, barrierDismissible: false, builder: (context) => AlertDialog(
        key: const Key('same-robot-dialog'),
        title: Text(context.strings.sameRobotQuestion(name)),
        content: Text(context.strings.sameRobotHint(name, match.last)),
        actions: [
          TextButton(key: const Key('same-robot-no'), onPressed: () => Navigator.pop(context, false), child: Text(context.strings.differentRobot)),
          FilledButton(key: const Key('same-robot-yes'), onPressed: () => Navigator.pop(context, true), child: Text(context.strings.sameRobot)),
        ],
      ));
      if (same == true) {
        await identity.link(_address, match.storeKey);
        key = match.storeKey;
      } else {
        await identity.markDistinct(_address, match.storeKey);
      }
    }
    await identity.remember(key, fingerprint: fingerprint, label: label, address: widget.address ?? _address);
    return key;
  }

  _Robot _make(String namespace) {
    final r = _Robot(RobotSession(connection: widget.connection, ip: widget.ip,
        port: widget.port, namespace: namespace, connectionFactory: widget.connectionFactory, storeKey: _storeKey), _report)
      ..start(_notifier);
    r.session.memory.load(); // its name for the title and the robot picker
    _watchRobot(r);
    r.watchDiagnostics();
    r.watchBattery(() {
      _updatePresence();
      if (mounted) setState(() {}); // the battery in the status line
    });
    return r;
  }

  void _warnLinkLost(List<String> robotNames) {
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      key: const Key('link-lost-dialog'),
      icon: const Icon(Icons.warning_amber_rounded, color: Color(0xFFB71C1C), size: 36),
      title: Text(context.strings.connectionLost),
      content: SingleChildScrollView(child: Text([
        context.strings.linkLossMoving,
        if (robotNames.length > 1) context.strings.movingRobots(robotNames.join(', ')),
      ].join('\n\n'))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.ok))],
    ));
  }

  void _report(_Robot robot, String message) {
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void initState() {
    super.initState();
    _presence = widget.presence ?? (ForegroundPresence.supported ? ForegroundPresence.instance : null);
    // The notification's Stop button stops everything, like Stop all.
    _presenceActions = _presence?.actions.listen((a) {
      if (a == 'stop' && mounted) stopAll();
    });
    // So does the home screen widget's (it opens the app with mobileros://stop).
    void widgetAction(String a) {
      if (!mounted) return;
      if (a == 'stop') stopAll();
      if (a.startsWith('run:')) _runFromWidget(a.substring(4));
    }
    _widgetActions = RobotWidget.actions.listen(widgetAction);
    // A tap that opened the app (e.g. Run while it was in the background and its screen had closed).
    final pending = RobotWidget.takePending();
    if (pending != null) WidgetsBinding.instance.addPostFrameCallback((_) => widgetAction(pending));
    // The countdown and "Next:" line refresh now and then.
    _presenceTimer = Timer.periodic(const Duration(seconds: 15), (_) => _updatePresence());
    robots = [_make('')];
    WidgetsBinding.instance.addPostFrameCallback((_) => _updatePresence());
    _connectionSubscription = widget.connection.messages.listen((_) {}, onDone: () {
      if (!mounted) return;
      setState(() {});
      _updatePresence();
      // The AI or a routine may have been driving with no control screen open: say so loudly.
      final now = DateTime.now();
      final moving = robots.where((r) => lostWhileMoving(lastMotion: r.session.drive.lastMotionAt,
          movingNow: !r.session.drive.current.isStop, now: now)).map((r) => r.session.name).toList();
      if (moving.isNotEmpty) {
        _warnLinkLost(moving);
        // The dialog is not seen with the screen off or another app in front: a notification is.
        for (final r in robots.where((r) => moving.contains(r.session.name))) {
          r.session.requests.add(RobotNotice(r.session.name, appStrings.linkLossMoving, NoticeLevel.error));
          r.recorder.record(IncidentKind.link, appStrings.connectionLost, level: 'error');
          r.saveIncident(appStrings.reasonLinkLost);
        }
      }
    });
    SystemRobotNotifier.create().then((n) {
      _notifier = n;
      if (mounted && n != null) {
        for (final r in robots) {
          r.session.requests.notifier = n;
        }
      }
    });
    _findRobots();
  }

  /// Looks for several robots (namespaces) on the connection and gives each its own session.
  Future<void> _findRobots() async {
    final List<String> found;
    try {
      final caps = await RobotCapabilities.discover(widget.connection);
      found = caps.robotNamespaces();
      if (mounted && !_closing && caps.topicNames.isNotEmpty) {
        final summary = RobotSummary.from(caps);
        final label = found.length > 1 ? appStrings.robotCount(found.length) : summary.model ?? summary.kindIn();
        try {
          final key = await _identify(caps, label);
          if (mounted && key != _storeKey) {
            _storeKey = key;
            if (found.isEmpty || (found.length == 1 && found.single.isEmpty)) {
              // A lone robot: its session is made again under the robot's saved key.
              final old = robots;
              setState(() { robots = [_make('')]; active = 0; });
              for (final r in old) { r.dispose(); }
            }
          }
        } catch (_) {
          // Recognising the robot is a convenience: the workspace works without it.
        }
        if (!mounted) return;
        widget.onRobotIdentified?.call(label);
        setState(() => robotLabel = label);
        RobotWidget.rememberRobot(label);
        _updatePresence();
      }
    } catch (_) {
      return;
    }
    if (!mounted || found.isEmpty || (found.length == 1 && found.single.isEmpty)) return;
    final old = robots;
    setState(() {
      robots = [for (final ns in found) _make(ns)];
      active = 0;
    });
    for (final r in old) {
      r.dispose();
    }
  }

  /// Stops every robot on the connection: motion, navigation goals and running routines.
  void stopAll() {
    for (final r in robots) {
      r.routineAgent.stop();
      r.session.nav.cancel();
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(
        robots.length > 1 ? context.strings.stopAllRequested : context.strings.stopRequested)));
  }

  @override
  void dispose() {
    _closing = true;
    _presenceVersion++;
    _connectionSubscription?.cancel();
    _presenceTimer?.cancel();
    _presenceActions?.cancel();
    _widgetActions?.cancel();
    _presence?.hide();
    RobotWidget.disconnected();
    for (final r in robots) {
      r.dispose();
    }
    widget.connection.close();
    super.dispose();
  }

  void _disconnect() {
    widget.connection.close();
    Navigator.pop(context);
  }

  /// Back to the connection screen, which connects to the same robot again at once.
  void _reconnect() {
    widget.connection.close();
    Navigator.pop(context, true);
  }

  void _open(Widget page) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final online = !widget.connection.isClosed;
    void openMap() => _open(MapVisualizationPage(ip: widget.ip, port: widget.port,
        connectionFactory: widget.connectionFactory, capabilities: session.capabilities, nav: session.nav,
        places: session.places, namespace: session.namespace, storeAddress: session.storeAddress, drive: session.drive,
        prepare: session.prepare,
        initial3d: _homeMapKeys[session.namespace]?.currentState?.view3d ?? false, robotLog: session.robotLog));
    // The four things people do, as icons with a short name; the rest under "More".
    List<_Tool> mainTools() {
      final log = session.robotLog, fresh = log.unseenProblems;
      return [
        _Tool(key: const Key('tool-control'), title: context.strings.drive, description: context.strings.driveHint,
          icon: Icons.sports_esports_outlined, accent: const Color(0xFF087F8C),
          onTap: online ? () => _open(ControlScreen(ip: widget.ip, port: widget.port, channel: widget.connection,
            imageConnectionFactory: widget.connectionFactory, capabilities: session.capabilities,
            drive: session.drive, namespace: session.namespace, navigation: session.nav, storeAddress: session.storeAddress,
            armPoses: session.armPoses)) : null),
        _Tool(key: const Key('tool-map'), title: context.strings.map, description: context.strings.mapHint,
          icon: Icons.map_outlined, accent: const Color(0xFF277A59), onTap: online ? openMap : null),
        _Tool(key: const Key('tool-ai'), title: context.strings.aiRoutines,
          description: context.strings.aiHint, icon: Icons.smart_toy_outlined,
          accent: const Color(0xFF5365C6),
          onTap: online ? () => _open(AssistantPage(session: session, log: robots[active].log,
            routineAgent: robots[active].routineAgent, startOnRoutines: robots[active].routineAgent.busy)) : null),
        _Tool(key: const Key('tool-status'), title: context.strings.status,
          description: fresh > 0 ? context.strings.warningCount(fresh)
              : context.strings.statusHint,
          icon: Icons.monitor_heart_outlined, accent: const Color(0xFF79648D), badge: fresh,
          // The log is still readable after a disconnect: that is when you want to know what happened.
          onTap: online || log.entries.isNotEmpty ? () => _open(RobotStatusPage(ip: widget.ip, port: widget.port,
            connectionFactory: widget.connectionFactory, log: log, online: online, startOnLog: fresh > 0)) : null),
      ];
    }
    final developerTools = <_Tool>[
      _Tool(key: const Key('tool-explorer'), title: context.strings.rosExplorer, description: context.strings.rosExplorerHint,
        icon: Icons.hub_outlined, accent: const Color(0xFF5365C6),
        onTap: online ? () => _open(ExplorerPage(ip: widget.ip, port: widget.port, connectionFactory: widget.connectionFactory)) : null),
      _Tool(key: const Key('tool-publish'), title: context.strings.publishMessage, description: context.strings.publishMessageHint,
        icon: Icons.send_outlined, accent: const Color(0xFF986334),
        onTap: online ? () => _open(PublishPage(ip: widget.ip, port: widget.port, connectionFactory: widget.connectionFactory)) : null),
    ];
    // The robot home's parts; a phone stacks them, a tablet puts the map beside them.
    Widget mapView(double height) => MiniMap(
        key: _homeMapKeys.putIfAbsent(session.namespace, () => GlobalKey<MiniMapState>()), connection: widget.connection,
        capabilities: session.capabilities, namespace: session.namespace, height: height, onTap: openMap, allow3d: true,
        places: session.places,
        onSnapshot: RobotWidget.supported ? _onMapSnapshot : null);
    final top = <Widget>[
      _statusLine(theme, online),
      // The first meeting, once per robot: it asks its name, its job and what to keep in mind.
      if (online) ...[
        const SizedBox(height: 12),
        RobotIntroCard(key: ValueKey('intro-${session.storeAddress}'), session: session,
            recognisedAs: robots.length == 1 ? robotLabel : null),
      ],
      if (online && robots.length > 1) ...[
        const SizedBox(height: 12),
        _robotPicker(theme),
      ],
    ];
    final tools = ListenableBuilder(listenable: session.robotLog,
        builder: (context, _) => _quickGrid(mainTools(), columns: 4));
    final more = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.only(left: 4, bottom: 4), child: Text(context.strings.more,
        style: theme.textTheme.labelLarge?.copyWith(color: context.muted, fontWeight: FontWeight.w700))),
      Card(margin: EdgeInsets.zero, child: Column(children: [
        ListTile(key: const Key('tool-tune'), leading: const Icon(Icons.tune), title: Text(context.strings.tuneRobot),
          trailing: const Icon(Icons.chevron_right), enabled: online,
          onTap: () => _open(TuneRobotPage(session: session))),
        if (robots.length > 1) ListTile(key: const Key('tool-fleet'), leading: const Icon(Icons.groups_outlined),
          title: Text(context.strings.fleet), trailing: const Icon(Icons.chevron_right), enabled: online,
          onTap: () => _open(FleetPage(sessions: [for (final r in robots) r.session]))),
        if (online) ListTile(key: const Key('robot-profile'), leading: const Icon(Icons.badge_outlined),
          title: Text(context.strings.namePersonality), subtitle: Text(context.strings.memoryHint),
          trailing: const Icon(Icons.chevron_right), onTap: () => _open(RobotMemoryPage(session: session,
            others: [for (final r in robots) if (r.session != session) r.session]))),
        ListTile(key: const Key('incidents'), leading: const Icon(Icons.history),
          title: Text(context.strings.incidentRecords), subtitle: Text(context.strings.incidentRecordsHint),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {
            final robot = robots.where((r) => r.session == session).firstOrNull;
            _open(IncidentsPage(store: _Robot.incidents,
              saveNow: online && robot != null && _Robot.incidents.available
                  ? () => robot.saveIncident(appStrings.reasonManual) : null));
          }),
        if (online) ListTile(key: const Key('about-robot'), leading: const Icon(Icons.info_outline),
          title: Text(context.strings.aboutRobot), trailing: const Icon(Icons.chevron_right),
          onTap: () => showModalBottomSheet<void>(context: context, isScrollControlled: true,
            showDragHandle: true, builder: (_) => SafeArea(child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: RobotSummaryCard(key: ValueKey('summary-${session.namespace}'), session: session,
                connectionKind: switch (widget.connection) {
                  DirectRosConnection() => 'DDS',
                  ZenohRosConnection() => 'Zenoh',
                  FoxgloveRosConnection() => 'Foxglove',
                  _ => 'rosbridge',
                }))))),
        // Remote access (account preview): the app installs Mobile ROS on the robot computer over SSH.
        if (cloudAccountsEnabled && !kIsWeb && online && widget.connection is! CloudRosConnection)
          ListTile(key: const Key('remote-access'), leading: const Icon(Icons.cloud_outlined),
            title: Text(context.strings.remoteAccess), subtitle: Text(context.strings.remoteAccessHint),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _open(RemoteSetupPage(host: _computerHost(), name: robotLabel ?? 'My robot'))),
        FutureBuilder<bool>(future: _canPinWidget, builder: (context, snap) => snap.data != true
            ? const SizedBox.shrink()
            : ListTile(key: const Key('add-widget'), leading: const Icon(Icons.widgets_outlined),
                title: Text(context.strings.addWidget), onTap: RobotWidget.pin)),
        ExpansionTile(key: const Key('developer-tools'), shape: const Border(),
          leading: const Icon(Icons.code), title: Text(context.strings.developerTools),
          children: [Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: _quickGrid(developerTools))]),
      ])),
    ]);
    // A stray back gesture must not drop the robot (it may be driving): ask first, unless the link is
    // already gone. The Disconnect and Reconnect buttons leave directly.
    return PopScope(canPop: !online, onPopInvokedWithResult: (didPop, _) async {
      if (didPop) return;
      final leave = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
        key: const Key('leave-dialog'),
        title: Text(context.strings.disconnectQuestion),
        content: Text(context.strings.disconnectDetail),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.strings.stay)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.strings.disconnect)),
        ],
      ));
      if (leave == true && mounted) _disconnect();
    }, child: Scaffold(
      appBar: AppBar(
        // The name the person gave a lone robot, else what it was recognised as.
        title: ListenableBuilder(listenable: session.memory, builder: (_, _) => Text(
          robots.length > 1 ? context.strings.robotCount(robots.length)
              : session.memory.profile(RobotPersona.nameKey) != null ? session.label : robotLabel ?? context.strings.robot,
          key: const Key('home-title'), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w800))),
        actions: [
          if (widget.connection case final DirectRosConnection direct)
            IconButton(key: const Key('message-definitions'), tooltip: context.strings.messageDefinitions,
              icon: const Icon(Icons.data_object),
              onPressed: () => _open(MessageDefinitionsPage(session: direct.session))),
          IconButton(tooltip: context.strings.disconnectReturn, onPressed: _disconnect,
          icon: const Icon(Icons.logout))],
      ),
      // The robot can ask the person something (or notify them) while any tool is open.
      body: _withRequestHosts(SafeArea(child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1400),
          child: FutureBuilder<RobotCapabilities>(future: session.capabilities(), builder: (context, snapshot) {
            final showMap = online && (snapshot.data?.topicsOfType('nav_msgs/OccupancyGrid').isNotEmpty ?? false);
            return LayoutBuilder(builder: (context, box) {
            // A tablet (or a phone on its side): a large live map next to the controls.
            if (showMap && box.maxWidth >= 840) {
              final mapHeight = (MediaQuery.sizeOf(context).height - 140).clamp(360.0, 900.0);
              return Row(key: const Key('home-wide'), crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  ...top,
                  const SizedBox(height: 16),
                  tools,
                  const SizedBox(height: 20),
                  more,
                ])),
                if (online) ...[
                  const SizedBox(width: 20),
                  Expanded(flex: 6, child: mapView(mapHeight)),
                ],
              ]);
            }
            return Align(alignment: Alignment.topCenter, child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 808),
              child: Column(key: const Key('home-stacked'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...top,
              // Where the robot is, at a glance (only when it has a map); a tap opens the map.
              // Taller on a tall screen (a tablet held upright), so the page is not half empty.
              if (showMap) Padding(padding: const EdgeInsets.only(top: 12),
                child: mapView((MediaQuery.sizeOf(context).height * 0.35).clamp(170.0, 460.0))),
              const SizedBox(height: 16),
              tools,
              const SizedBox(height: 20),
              more,
            ])));
            });
          }),
        )),
      ))),
    ));
  }

  /// Icon tiles: 3 across on a phone, more on wider screens.
  Widget _quickGrid(List<_Tool> tools, {int? columns}) => LayoutBuilder(builder: (context, constraints) {
    final requested = columns ?? (constraints.maxWidth >= 900 ? 6 : constraints.maxWidth >= 560 ? 4 : 3);
    final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    final minWidth = 60 + (scale - 1).clamp(0, 2) * 60;
    final count = ((constraints.maxWidth + 10) / (minWidth + 10)).floor().clamp(1, requested);
    final width = (constraints.maxWidth - 10 * (count - 1)) / count;
    return Wrap(spacing: 10, runSpacing: 10,
      children: [for (final t in tools) SizedBox(width: width, child: _QuickTile(tool: t))]);
  });

  /// The robot at a glance: connected or not, what it is doing, its battery, and STOP (or Reconnect).
  Widget _statusLine(ThemeData theme, bool online) {
    final address = widget.address ?? '${widget.ip}:${widget.port}';
    final r = robots.isEmpty ? null : robots[active];
    return ListenableBuilder(
      listenable: Listenable.merge([if (r != null) r.routineAgent, if (r != null) r.session.nav]),
      builder: (context, _) {
        final routine = r?.routineAgent.progress;
        final navigating = r?.session.nav.status == NavStatus.active;
        final doing = !online ? address
            : routine != null ? '${routine.routine} · ${routine.roundText(context.strings)}'
            : navigating ? context.strings.drivingToGoal : address;
        final battery = r?.battery ?? '';
        final compact = MediaQuery.textScalerOf(context).scale(10) > 13 || MediaQuery.sizeOf(context).width < 360;
        return Container(
          key: const Key('connection-status'),
          padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
          decoration: BoxDecoration(
            color: online ? const Color(0xFF182D42) : const Color(0xFF5C1A14),
            borderRadius: BorderRadius.circular(18)),
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(shape: BoxShape.circle,
              color: online ? const Color(0xFF78E0CE) : const Color(0xFFFF8A80))),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(online ? context.strings.connected : context.strings.disconnected,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                if (online && battery.isNotEmpty) Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.battery_std, size: 16, color: Color(0xFF78E0CE)),
                  Text(battery, key: const Key('home-battery'),
                    style: const TextStyle(color: Color(0xFF78E0CE), fontWeight: FontWeight.w700, fontSize: 13)),
                ]),
              ]),
              const SizedBox(height: 2),
              Text(doing, key: const Key('home-doing'), maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFFCDD9E3), fontSize: 13)),
            ])),
            const SizedBox(width: 8),
            // With large text or a narrow screen the buttons keep their icon only.
            if (online)
              compact
                  ? IconButton.filled(key: const Key('stop-all'), onPressed: stopAll,
                      tooltip: robots.length > 1 ? context.strings.stopAll : context.strings.stop,
                      style: IconButton.styleFrom(backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white),
                      icon: const Icon(Icons.pan_tool))
                  : FilledButton.icon(key: const Key('stop-all'), onPressed: stopAll,
                      style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD32F2F),
                        foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 14)),
                      icon: const Icon(Icons.pan_tool, size: 18),
                      label: Text(robots.length > 1 ? context.strings.stopAll : context.strings.stop,
                        style: const TextStyle(fontWeight: FontWeight.w800)))
            else
              compact
                  ? IconButton.filled(key: const Key('reconnect'), onPressed: _reconnect, tooltip: context.strings.reconnect,
                      icon: const Icon(Icons.refresh))
                  : FilledButton.icon(key: const Key('reconnect'), onPressed: _reconnect,
                      icon: const Icon(Icons.refresh, size: 18), label: Text(context.strings.reconnect)),
          ]),
        );
      });
  }

  /// The robot's questions can come while any robot is selected: every robot gets a listener.
  Widget _withRequestHosts(Widget child) {
    var w = child;
    for (final r in robots.reversed) {
      w = RobotRequestsHost(key: ValueKey('requests-${r.session.namespace}'), requests: r.session.requests,
          robotName: r.session.namespace.isEmpty ? widget.address ?? r.session.name : r.session.name, child: w);
    }
    return w;
  }

  Widget _robotPicker(ThemeData theme) => Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
    Expanded(child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(context.strings.robotCount(robots.length), style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
      for (final (i, r) in robots.indexed)
        ChoiceChip(key: Key('robot-${r.session.name}'), label: ListenableBuilder(listenable: r.session.memory,
            builder: (_, _) => Text(r.session.label)), selected: i == active,
            avatar: const Icon(Icons.smart_toy_outlined, size: 18),
            onSelected: (_) => setState(() => active = i)),
    ])),
  ]);
}

/// A tool on the workspace: what it is, how it looks, and what opens.
class _Tool {
  const _Tool({required this.key, required this.title, required this.description, required this.icon,
    required this.accent, this.onTap, this.badge = 0});
  final Key key;
  final String title, description;
  final IconData icon;
  final Color accent;
  final VoidCallback? onTap;
  /// Something new to look at (new problems in the log), shown as a count.
  final int badge;
}

Widget _badge(BuildContext context, int n) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
  decoration: BoxDecoration(color: Theme.of(context).colorScheme.error, borderRadius: BorderRadius.circular(10)),
  child: Text(n > 99 ? '99+' : '$n',
    style: TextStyle(color: Theme.of(context).colorScheme.onError, fontWeight: FontWeight.w800, fontSize: 12)));

/// A tool in the grid: an icon and its name (the longer description is read out by screen readers
/// and shown on long press).
class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.tool});
  final _Tool tool;

  @override
  Widget build(BuildContext context) {
    final t = tool, theme = Theme.of(context), enabled = t.onTap != null;
    final color = enabled ? t.accent : theme.disabledColor;
    return Tooltip(message: t.description, triggerMode: TooltipTriggerMode.longPress,
      child: Semantics(button: true, enabled: enabled, excludeSemantics: true,
        label: '${t.title}. ${t.description}',
        child: Material(key: t.key, color: enabled ? context.card : context.cardDisabled,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: context.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(onTap: t.onTap, child: Stack(children: [
            Padding(padding: const EdgeInsets.fromLTRB(8, 14, 8, 12), child: Column(children: [
              Container(width: 44, height: 44, alignment: Alignment.center,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(14)),
                child: Icon(t.icon, color: color, size: 24)),
              const SizedBox(height: 8),
              ConstrainedBox(constraints: BoxConstraints(minHeight: MediaQuery.textScalerOf(context).scale(13) * 2.5),
                child: Center(child: Text(t.title, textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, height: 1.25, color: context.ink)))),
              const SizedBox(height: 4),
            ])),
            if (t.badge > 0) Positioned(top: 6, right: 6,
              child: KeyedSubtree(key: Key('tool-badge-${t.title}'), child: _badge(context, t.badge))),
          ])))));
  }
}
