import 'learned_tools.dart';
import 'learning.dart';
import '../memory.dart';
import '../robot_persona.dart';
import 'dart:async';
import 'package:flutter/foundation.dart';
import '../l10n/generated/app_localizations.dart';
import '../controllers/arm_controller.dart';
import '../controllers/drive_controller.dart';
import '../controllers/navigation_controller.dart';
import '../controllers/odometry.dart';
import '../places.dart';
import '../routines.dart';
import '../robot_session.dart';
import 'audit_log.dart';
import 'executor.dart';
import 'manifest.dart';
import 'instruction_language.dart';
import 'robot_tools.dart';
import 'skill.dart';
import 'validator.dart';

/// What a backend is given for one instruction.
class AgentRequest {
  const AgentRequest({required this.instruction, required this.manifest, required this.status, this.robots = const {}});

  final String instruction;
  final AgentManifest manifest;
  /// The robot's current state (see [SkillExecutor.status]).
  final Map<String, Object?> status;
  /// For a fleet: each robot's own tool list, by robot name ([manifest] is then the fleet's).
  final Map<String, AgentManifest> robots;
}

/// A backend's answer: skills to run in order, and optionally something to say. No calls means the
/// backend is done with the instruction.
class AgentPlan {
  const AgentPlan({this.calls = const [], this.reply});

  final List<SkillCall> calls;
  final String? reply;
}

/// Turns an instruction into skill calls. Cloud and on-device language models implement this; tests use
/// a scripted one. Backends only plan; they never touch the robot.
///
/// One instruction is a short conversation: [plan] starts it, and as long as the plan has calls the
/// agent runs them and hands the outcomes to [continueWith], which returns the next plan. A backend that
/// plans everything up front returns an empty plan from [continueWith] (the default).
abstract class AgentBackend {
  /// Short name for the audit log, e.g. "cloud" or "local".
  String get name;

  Future<AgentPlan> plan(AgentRequest request);

  /// The results of the last plan's calls, in the same order (each carries the call's id).
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) async => const AgentPlan();
}

/// Where a running routine is: shown on screen and in the background notification.
class RoutineProgress {
  const RoutineProgress({required this.routine, required this.round, required this.rounds, this.step = 0,
    this.steps = 0, this.doing = '', this.waitingUntil});
  final String routine;
  /// 1-based; [rounds] 0 means until stopped.
  final int round, rounds;
  /// 1-based step within the round, of [steps].
  final int step, steps;
  /// The current step, readable ("Go to a saved place · kitchen").
  final String doing;
  /// Set while waiting between rounds.
  final DateTime? waitingUntil;

  String roundText(AppLocalizations s) => rounds == 0 ? s.routineRound(round) : s.routineRoundOf(round, rounds);

  RoutineProgress copyWith({int? round, int? step, int? steps, String? doing, DateTime? waitingUntil,
      bool clearWait = false}) => RoutineProgress(routine: routine, round: round ?? this.round, rounds: rounds,
      step: step ?? this.step, steps: steps ?? this.steps, doing: doing ?? this.doing,
      waitingUntil: clearWait ? null : waitingUntil ?? this.waitingUntil);
}

/// The result of one instruction.
class AgentRun {
  const AgentRun({required this.instruction, this.replies = const [], this.results = const [], this.error});

  final String instruction;
  /// What the backend said along the way, in order.
  final List<String> replies;
  final List<SkillResult> results;
  /// Set when no plan could be made (backend failure), the agent was busy, or a stop interrupted it.
  final String? error;

  bool get ok => error == null && results.every((r) => r.ok);
}

/// Natural language in, robot motion out, with every step checked and recorded:
/// instruction → backend plan → validate each call → execute through the session controllers → log,
/// then the outcomes go back to the backend for the next step until it has nothing more to do.
///
/// A stop word ("멈춰", "stop", …) never waits for a model: it stops the robot at once, even while
/// another instruction is running.
class RobotAgent extends ChangeNotifier {
  RobotAgent({required this.drive, required this.nav, required this.backend, AuditLog? log, Odometry? odometry,
      this.places, this.routines, this.prepare, this.tools, this.arm, this.armPoses, this.memory, Memory? userMemory,
      this.limits = const AgentLimits(),
      this.maxCallsPerPlan = 10, this.maxRounds = 8})
      : log = log ?? AuditLog(),
        userMemory = userMemory ?? Memory.user,
        _executor = SkillExecutor(drive: drive, nav: nav, odometry: odometry, arm: arm, armPoses: armPoses);

  /// An agent on [session]'s controllers; the session is prepared (topics advertised) on first use.
  factory RobotAgent.forSession(RobotSession session, AgentBackend backend, {AuditLog? log}) =>
      RobotAgent(drive: session.drive, nav: session.nav, backend: backend, log: log, odometry: session.odometry,
          places: session.places, routines: session.routines, prepare: session.prepare,
          tools: RobotTools.forSession(session), arm: session.arm, armPoses: session.armPoses,
          memory: session.memory);

  final DriveController drive;
  final NavigationController nav;
  /// Saved places the agent may go to by name.
  final PlaceBook? places;
  /// Saved routines the agent may run by name and save new ones into.
  /// The robot's arm and the postures it may be moved to (null: no arm skills).
  final ArmController? arm;
  final ArmPoseBook? armPoses;
  final RoutineBook? routines;
  /// What the assistant knows about this robot and its person: given to the model with the tool list,
  /// and added to with update_profile and remember.
  final Memory? memory;
  final Memory userMemory;
  AgentBackend backend;
  final AuditLog log;
  /// Makes the controllers ready before planning (see [RobotSession.prepare]).
  final Future<void> Function()? prepare;
  /// Health, position and map tools (check_robot, find_position, save_place, save_map).
  final RobotTools? tools;
  final AgentLimits limits;
  final int maxCallsPerPlan;
  /// Most plan → run → report cycles for one instruction, so a confused model cannot loop forever.
  final int maxRounds;
  final SkillExecutor _executor;

  bool _busy = false;
  bool _disposed = false;

  // A backend or a routine's wait may finish after its workspace and audit log have closed.
  void _record(AuditEntry entry) {
    if (!_disposed) log.add(entry);
  }

  @override
  void dispose() {
    if (_disposed) return;
    if (drive.automation.ownedBy(this)) { stop(); } else { _generation++; }
    _disposed = true;
    super.dispose();
  }
  /// The routine running now (null when none), for progress on screen and in the notification.
  RoutineProgress? progress;
  /// Describes a step for [progress]; the app passes its people-facing labels.
  String Function(SkillCall call)? describeStep;
  int _generation = 0; // bumped by stop, so a running instruction notices it was interrupted
  /// Actions carried out in the current instruction, and in the last one that did any: what
  /// save_routine saves.
  List<SkillCall> _ranNow = [];
  List<SkillCall> _ranBefore = const [];

  /// Skills that are not worth replaying in a routine.
  static const _notSaved = {'stop', 'get_status', 'look', 'save_routine', 'cancel_navigation', 'check_robot',
    'save_place', 'save_map', 'update_profile', 'remember', 'learn_phrase', 'define_tool'};

  bool get busy => _busy;

  /// Whether [instruction] is a bare stop command, handled without a model.
  static bool isStopWord(String instruction) => InstructionLanguagePolicy.isStopWord(instruction);

  /// The manifest as of now (the profile or navigation setup may change while connected).
  AgentManifest manifest({String query = ''}) =>
      AgentManifest.build(profile: drive.profile, nav: nav, limits: limits, places: places?.usable ?? const [],
          routines: [for (final r in routines?.routines ?? const <Routine>[]) r.name], canSaveRoutines: routines != null,
          abilities: tools?.abilities,
          armPoses: arm?.configured == true ? armPoses?.names() ?? const [] : const [],
          hasGripper: arm?.configured == true && arm!.hasGripper,
          persona: memory == null ? null : RobotPersona.from(memory!, userMemory, query: query),
          canRemember: memory != null,
          learned: memory == null ? const [] : LearnedTool.from(memory!, query: query),
          aliases: memory == null ? const {} : Learning.aliases(userMemory));

  /// What the robot is doing now, as given to backends.
  Map<String, Object?> status() => _executor.status();

  /// Carries out [instruction], then keeps a line about it in the robot's memory (what was asked and how
  /// it went), which the online assistant reads later ("like yesterday", "what did you do?").
  Future<AgentRun> handle(String instruction) async {
    final run = await _handle(instruction);
    try {
      await rememberRun(memory, run, calls: _ranNow);
    } catch (e) {
      // Memory is a convenience: a storage failure must never turn a done command into an error.
      _record(AuditEntry(AuditKind.note, 'Could not save to memory: $e'));
    }
    return run;
  }

  /// Saves [run] as an episode in [memory] (not stops, refusals of a busy robot, or plain remembering).
  /// [calls]: what the request carried out; the same calls asked for again and again become a learned tool.
  static Future<void> rememberRun(Memory? memory, AgentRun run, {String prefix = '', List<SkillCall> calls = const []}) async {
    if (memory == null || isStopWord(run.instruction) || run.error?.startsWith('Still working') == true) return;
    if (run.results.isNotEmpty && run.results.every((r) => r.message.startsWith('Saved:') ||
        r.message.startsWith('Noted:') || r.message.startsWith('I will call you'))) {
      return; // already in the profile
    }
    final text = RobotPersona.episodeText(memory.now, '$prefix${run.instruction}',
        results: [for (final r in run.results) r.message], replies: run.replies, error: run.error);
    final learnable = run.ok && calls.isNotEmpty &&
        calls.every((c) => !Learning.notLearned.contains(c.name) && !c.name.startsWith(LearnedTool.prefix));
    if (text != null) {
      await memory.add('episode', text, source: 'app', data: learnable && prefix.isEmpty
          ? {'sig': LearnedTool.signatureOf(calls), 'say': run.instruction} : null);
    }
    if (run.ok && prefix.isEmpty) await Learning.observe(memory, run.instruction, calls);
    await Learning.compact(memory);
  }

  Future<AgentRun> _handle(String instruction) async {
    final text = instruction.trim();
    if (_disposed) return AgentRun(instruction: text, error: 'This assistant has closed.');
    _record(AuditEntry(AuditKind.instruction, text, source: 'person'));
    if (isStopWord(text)) {
      stop();
      return AgentRun(instruction: text, results: const [SkillResult(true, 'Stopped.')]);
    }
    if (_busy) {
      const error = 'Still working on the previous instruction. Say "stop" to interrupt it.';
      _record(AuditEntry(AuditKind.note, error));
      return AgentRun(instruction: text, error: error);
    }
    if (!drive.automation.acquire(this, stop)) {
      const error = 'Another instruction or routine is running on this robot. Stop it before starting another.';
      _record(AuditEntry(AuditKind.note, error));
      return AgentRun(instruction: text, error: error);
    }
    _setBusy(true);
    _ranNow = [];
    final generation = _generation;
    final replies = <String>[];
    final results = <SkillResult>[];
    AgentRun finish({String? error}) =>
        AgentRun(instruction: text, replies: replies, results: results, error: error);
    try {
      await prepare?.call();
      await tools?.refresh();
      final manifest = this.manifest(query: text);
      AgentPlan plan;
      try {
        plan = await backend.plan(AgentRequest(instruction: text, manifest: manifest, status: status()));
      } catch (e) {
        return finish(error: _backendFailed(e));
      }
      for (var round = 1;; round++) {
        final reply = plan.reply?.trim();
        if (reply != null && reply.isNotEmpty) {
          replies.add(reply);
          _record(AuditEntry(AuditKind.plan, reply, source: backend.name));
        }
        if (generation != _generation) {
          _record(AuditEntry(AuditKind.note, 'Interrupted by stop.'));
          return finish(error: 'Interrupted by stop.');
        }
        if (plan.calls.isEmpty) return finish();
        if (round > maxRounds) {
          const error = 'Gave up after too many steps for one instruction.';
          _record(AuditEntry(AuditKind.note, error, source: backend.name));
          return finish(error: error);
        }
        final ran = await _run(plan.calls, manifest: manifest, source: backend.name, generation: generation);
        results.addAll(ran.map((r) => r.$2));
        if (generation != _generation) {
          _record(AuditEntry(AuditKind.note, 'Interrupted by stop.'));
          return finish(error: 'Interrupted by stop.');
        }
        // A refused or failed step ends the instruction here: the robot does nothing more on its own.
        if (ran.length < plan.calls.length || ran.any((r) => !r.$2.ok)) return finish();
        try {
          plan = await backend.continueWith(ran);
        } catch (e) {
          return finish(error: _backendFailed(e));
        }
      }
    } finally {
      if (_ranNow.isNotEmpty) _ranBefore = _ranNow;
      _setBusy(false);
    }
  }

  /// Runs a saved routine directly (from the routines screen or a schedule), without a model. [source]
  /// says who started it, e.g. "person" or "schedule". It does [Routine.repeat] rounds ([repeat]
  /// overrides; 0 = until stopped) with [Routine.pauseSeconds] between them; a stop ends it at once, and
  /// a failed step ends the run.
  /// The shortest wait between rounds of a routine that repeats until stopped.
  static const minUntilStoppedPause = Duration(seconds: 1);

  Future<AgentRun> runRoutine(Routine routine, {String source = 'person', int? repeat, int? pauseSeconds}) async {
    if (_disposed) return AgentRun(instruction: routine.name, error: 'This assistant has closed.');
    final rounds = (repeat ?? routine.repeat).clamp(0, Routine.maxRepeat);
    // "Until stopped" always leaves a gap: a round of instant steps (a status check) with no pause would
    // otherwise run back to back without end, freezing the app (seen on a phone: 150 MB/s, then ANR).
    final asked = Duration(seconds: pauseSeconds ?? routine.pauseSeconds);
    final pause = rounds == 0 && asked < minUntilStoppedPause ? minUntilStoppedPause : asked;
    final text = 'Run routine "${routine.name}"${rounds == 1 ? '' : rounds == 0 ? ' until stopped' : ' $rounds times'}';
    _record(AuditEntry(AuditKind.instruction, text, source: source));
    if (_busy) {
      const error = 'Still working on the previous instruction. Say "stop" to interrupt it.';
      _record(AuditEntry(AuditKind.note, error));
      return AgentRun(instruction: text, error: error);
    }
    if (!drive.automation.acquire(this, stop)) {
      const error = 'Another instruction or routine is running on this robot. Stop it before starting another.';
      _record(AuditEntry(AuditKind.note, error));
      return AgentRun(instruction: text, error: error);
    }
    _setBusy(true);
    final generation = _generation;
    try {
      await prepare?.call();
      await tools?.refresh();
      final m = manifest();
      final results = <SkillResult>[];
      for (var round = 1; rounds == 0 || round <= rounds; round++) {
        if (round > 1 && pause > Duration.zero) {
          _progress(progress?.copyWith(step: 0, doing: '', waitingUntil: DateTime.now().add(pause)));
          // Waits in short slices so a stop ends the wait at once.
          final until = DateTime.now().add(pause);
          while (DateTime.now().isBefore(until) && generation == _generation) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
        if (generation != _generation) break;
        _progress(RoutineProgress(routine: routine.name, round: round, rounds: rounds));
        final r = await _runRoutine(routine, m, source: 'routine', generation: generation);
        results.add(r);
        // Running until stopped: keep the recent rounds only.
        if (results.length > 20) results.removeAt(0);
        if (generation != _generation || !r.ok) break;
        // Let the screen, the notification and a stop in between every round.
        await Future<void>.delayed(Duration.zero);
      }
      if (rounds != 1 && results.isNotEmpty && results.last.ok && generation == _generation) {
        results.add(SkillResult(true, 'Ran "${routine.name}" ${rounds == 0 ? 'until stopped' : '${results.length} times'}.'));
      }
      if (generation != _generation) return AgentRun(instruction: text, results: results, error: 'Interrupted by stop.');
      return AgentRun(instruction: text, results: results);
    } catch (e) {
      _record(AuditEntry(AuditKind.note, '$e'));
      return AgentRun(instruction: text, error: '$e');
    } finally {
      _progress(null);
      _setBusy(false);
    }
  }

  void _progress(RoutineProgress? p) {
    progress = p;
    if (!_disposed) notifyListeners();
  }

  Future<SkillResult> _runRoutine(Routine routine, AgentManifest m, {String? source, required int generation}) async {
    final book = routines;
    final List<SkillCall> calls;
    try {
      calls = (book ?? RoutineBook('')).expand(routine);
    } on RoutineError catch (e) {
      return SkillResult.failed('Cannot run "${routine.name}": ${e.message}');
    }
    if (calls.isEmpty) return SkillResult.failed('"${routine.name}" has no steps.');
    _record(AuditEntry(AuditKind.note, 'Routine "${routine.name}": ${calls.length} steps.', source: source));
    final ran = await _run(calls, manifest: m, source: source, generation: generation,
        limit: RoutineBook.maxCalls, record: false, onStep: (i, call) {
          final p = progress;
          if (p != null) {
            _progress(p.copyWith(step: i + 1, steps: calls.length, clearWait: true,
                doing: describeStep?.call(call) ?? call.name));
          }
        });
    final failed = ran.where((r) => !r.$2.ok).firstOrNull;
    if (failed != null) return SkillResult.failed('"${routine.name}" stopped at ${failed.$1.name}: ${failed.$2.message}');
    if (ran.length < calls.length) return SkillResult.failed('"${routine.name}" did not finish.');
    return SkillResult(true, 'Ran "${routine.name}" (${calls.length} steps).');
  }

  Future<SkillResult> _saveRoutine(String name) async {
    final book = routines;
    if (book == null) return const SkillResult.failed('Routines cannot be saved here.');
    final source = _ranNow.isNotEmpty ? _ranNow : _ranBefore;
    final steps = <RoutineStep>[
      for (final c in source)
        if (c.name == 'run_routine')
          if (book.find('${c.args['name']}') case final r?) RoutineStep.routine(r.id) else RoutineStep.call(c)
        else
          RoutineStep.call(SkillCall(c.name, c.args)),
    ];
    if (steps.isEmpty) return const SkillResult.failed('There are no actions to save yet. Do them first, then save.');
    try {
      final existing = book.find(name);
      if (!book.loaded) await book.load();
      final saved = await book.save(Routine(id: existing?.id ?? RoutineBook.newId(), name: name, steps: steps,
          schedules: existing?.schedules ?? const [], repeat: existing?.repeat ?? 1,
          pauseSeconds: existing?.pauseSeconds ?? 0));
      return SkillResult(true, 'Saved routine "${saved.name}" with ${steps.length} steps.');
    } on RoutineError catch (e) {
      return SkillResult.failed(e.message);
    }
  }

  /// Sets one of [RobotPersona.fields]: the robot's name, role, manner or kind, or what to call the person.
  Future<SkillResult> _updateProfile(String field, String value) async {
    final key = RobotPersona.fields[field];
    final m = memory;
    if (key == null || m == null) return SkillResult.failed('That cannot be saved.');
    final target = field == 'call_person' ? userMemory : m;
    await target.setProfile(key, value, source: 'assistant');
    return SkillResult(true, field == 'call_person' ? 'I will call you "$value".' : 'Saved: ${field.replaceAll('_', ' ')} is "$value".');
  }

  Future<SkillResult> _learnPhrase(String phrase, String meaning) async {
    if (memory == null || phrase.trim().isEmpty || meaning.trim().isEmpty) return SkillResult.failed('There was nothing to learn.');
    final why = Learning.unsafePhrase(phrase, meaning);
    if (why != null) return SkillResult.failed(why);
    await userMemory.put(Learning.aliasKind, phrase.trim(), meaning, source: 'assistant', pinned: true);
    return SkillResult(true, 'Learned: "${phrase.trim()}" means ${meaning.trim()}.');
  }

  Future<SkillResult> _defineTool(Map<String, Object?> args, AgentManifest m) async {
    final mem = memory;
    if (mem == null) return SkillResult.failed('Tools cannot be kept here.');
    final made = Learning.define(args, m);
    if (made.tool == null) return SkillResult.failed('Not made: ${made.error}');
    await LearnedTool.save(mem, made.tool!);
    return SkillResult(true, 'Made the tool ${made.tool!.name} (${made.tool!.steps.length} steps).');
  }

  /// A learned tool: its steps with the arguments filled in, each validated again for this robot.
  Future<SkillResult> _runLearned(String name, Map<String, Object?> args, AgentManifest m,
      {String? source, required int generation}) async {
    final tool = m.learned.where((t) => t.name == name).firstOrNull ??
        [for (final t in LearnedTool.from(memory ?? Memory('none'), limit: 100)) if (t.name == name) t].firstOrNull;
    if (tool == null) return SkillResult.failed('There is no tool $name.');
    final steps = tool.expand(args);
    final ran = await _run(steps, manifest: m.without({for (final t in m.learned) t.name}), source: source,
        generation: generation, limit: LearnedTool.maxSteps, record: false);
    final failed = ran.where((r) => !r.$2.ok).firstOrNull;
    if (failed != null) return SkillResult.failed('$name stopped at ${failed.$1.name}: ${failed.$2.message}');
    if (ran.length < steps.length) return SkillResult.failed('$name was interrupted.');
    return SkillResult(true, 'Did $name: ${ran.map((r) => r.$2.message).join(' ')}');
  }

  Future<SkillResult> _remember(String note) async {
    final m = memory;
    if (m == null) return SkillResult.failed('Notes cannot be saved here.');
    final saved = await m.add('note', note, source: 'assistant', pinned: true);
    return saved == null ? SkillResult.failed('There was nothing to remember.') : SkillResult(true, 'Noted: "${saved.text}".');
  }

  Future<SkillResult> _tool(Future<SkillResult> Function(RobotTools) run) async {
    final t = tools;
    if (t == null) return const SkillResult.failed('Not available here.');
    try {
      return await run(t);
    } catch (e) {
      return SkillResult.failed('$e');
    }
  }

  String _backendFailed(Object e) {
    final error = 'Could not plan with ${backend.name}: $e';
    _record(AuditEntry(AuditKind.note, error, source: backend.name));
    return error;
  }

  /// Validates and runs [calls] in order, stopping at the first refusal or failure.
  Future<List<SkillResult>> runCalls(List<SkillCall> calls, {AgentManifest? manifest, String? source}) async =>
      [for (final r in await _run(calls, manifest: manifest, source: source, generation: _generation)) r.$2];

  Future<List<(SkillCall, SkillResult)>> _run(List<SkillCall> calls, {AgentManifest? manifest, String? source,
      required int generation, int? limit, bool record = true, void Function(int index, SkillCall call)? onStep}) async {
    final m = manifest ?? this.manifest();
    final results = <(SkillCall, SkillResult)>[];
    final most = limit ?? maxCallsPerPlan;
    if (calls.length > most) {
      final r = SkillResult.failed('The plan has ${calls.length} steps; at most $most are allowed.');
      _record(AuditEntry(AuditKind.rejected, r.message, ok: false, source: source));
      return [(calls.first, r)];
    }
    for (final (index, call) in calls.indexed) {
      if (generation != _generation) {
        _record(AuditEntry(AuditKind.note, 'Stopped; the remaining steps were not run.'));
        break;
      }
      onStep?.call(index, call);
      final verdict = validateCall(call, m);
      if (!verdict.ok) {
        final r = SkillResult.failed(verdict.rejection!);
        _record(AuditEntry(AuditKind.rejected, '$call → ${verdict.rejection}', ok: false, source: source));
        results.add((call, r));
        break;
      }
      final checked = verdict.call!;
      _record(AuditEntry(AuditKind.call,
          '$checked${verdict.notes.isEmpty ? '' : ' (${verdict.notes.join('; ')})'}', source: source));
      var r = switch (checked.name) {
        'run_routine' => switch (routines?.find('${checked.args['name']}')) {
          final routine? => await _runRoutine(routine, m, source: source, generation: generation),
          null => SkillResult.failed('There is no routine "${checked.args['name']}".'),
        },
        'save_routine' => await _saveRoutine('${checked.args['name']}'),
        'update_profile' => await _updateProfile('${checked.args['field']}', '${checked.args['value']}'),
        'remember' => await _remember('${checked.args['note']}'),
        'learn_phrase' => await _learnPhrase('${checked.args['phrase']}', '${checked.args['meaning']}'),
        'define_tool' => await _defineTool(checked.args, m),
        final name when name.startsWith(LearnedTool.prefix) =>
            await _runLearned(name, checked.args, m, source: source, generation: generation),
        'check_robot' => await _tool((t) => t.checkRobot()),
        'find_position' => await _tool((t) => t.findPosition()),
        'save_place' => await _tool((t) => t.savePlace('${checked.args['name']}')),
        'save_map' => await _tool((t) => t.saveMap(checked.args['name'] as String?)),
        _ => await _executor.execute(checked, m),
      };
      if (record && r.ok && !_notSaved.contains(checked.name)) _ranNow.add(checked);
      if (verdict.notes.isNotEmpty) r = SkillResult(r.ok, '${r.message} Note: ${verdict.notes.join('; ')}.', r.data);
      _record(AuditEntry(AuditKind.result, r.message, ok: r.ok, source: source, image: r.image));
      results.add((checked, r));
      if (!r.ok) break;
    }
    return results;
  }

  /// Stops the robot now and abandons the rest of any running instruction.
  void stop() {
    if (_disposed) return;
    drive.automation.interrupt(this);
    _generation++;
    _executor.execute(const SkillCall('stop'), manifest());
    _record(AuditEntry(AuditKind.result, 'Stopped.', ok: true));
  }

  void _setBusy(bool value) {
    _busy = value;
    if (!value) drive.automation.release(this);
    if (!_disposed) notifyListeners();
  }
}
