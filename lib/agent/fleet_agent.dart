import '../robot_session.dart';
import '../routines.dart';
import 'agent.dart';
import 'local/fleet_local_backend.dart';
import 'manifest.dart';
import 'skill.dart';
import 'validator.dart';

/// Plans once for the fleet. Calls for each robot stay ordered, while different robots execute
/// concurrently through their own validated controllers.
///
/// With a [routines] book the fleet has routines of its own: what the fleet just did, saved with which
/// robot did each step ("robot1 to the dock, robot2 to the door" as "close up"), and run again later the
/// same way, every step validated again for its robot when it runs.
class FleetAgent {
  FleetAgent(this.sessions, this.backend, {this.routines}) : assert(sessions.isNotEmpty) {
    for (final session in sessions) {
      _agents[session.name] = RobotAgent.forSession(session, _NoPlanner());
    }
  }

  final List<RobotSession> sessions;
  final AgentBackend backend;
  final RoutineBook? routines;
  final _agents = <String, RobotAgent>{};
  bool busy = false;
  int _generation = 0;
  /// Robot actions done in the current instruction, and in the last one that did any: what
  /// save_routine saves (each call keeps its robot).
  List<SkillCall> _ranNow = [];
  List<SkillCall> _ranBefore = const [];

  /// Not worth replaying in a routine (as for one robot), plus the fleet's own routine skills.
  static const _notSaved = {'stop', 'get_status', 'look', 'save_routine', 'run_routine', 'cancel_navigation',
    'check_robot', 'save_place', 'save_map'};

  /// The book used for fleet routines on one connection (each robot keeps its own book too).
  static RoutineBook bookFor(RobotSession anyRobot) => RoutineBook('fleet:${anyRobot.storeKey}');

  Future<AgentManifest> manifest() async {
    await Future.wait(sessions.map((s) => s.prepare()));
    final book = routines;
    if (book != null && !book.loaded) await book.load();
    return AgentManifest.fleet({for (final s in sessions) s.name: _agents[s.name]!.manifest()},
        routines: [for (final r in book?.routines ?? const <Routine>[]) r.name], canSaveRoutines: book != null);
  }

  Future<AgentRun> _handle(String instruction) async {
    final text = instruction.trim();
    if (RobotAgent.isStopWord(text) || isFleetStop(text)) {
      stop();
      return AgentRun(instruction: text, results: const [SkillResult(true, 'All robots stopped.')]);
    }
    if (busy) return AgentRun(instruction: text, error: 'The fleet is still working.');
    busy = true;
    _ranNow = [];
    final generation = _generation;
    final results = <SkillResult>[];
    final replies = <String>[];
    try {
      final tools = await manifest();
      var plan = await backend.plan(AgentRequest(instruction: text, manifest: tools,
        status: {for (final entry in _agents.entries) entry.key: entry.value.status()},
        robots: {for (final entry in _agents.entries) entry.key: entry.value.manifest()}));
      for (var round = 0; round < 8; round++) {
        if (generation != _generation) {
          return AgentRun(instruction: text, results: results,
            replies: replies, error: 'Interrupted by stop.');
        }
        // Like a robot's own assistant: an empty answer (a model that only called tools) is not a reply.
        if (plan.reply?.trim() case final reply? when reply.isNotEmpty) { replies.add(reply); }
        if (plan.calls.isEmpty) return AgentRun(instruction: text, results: results, replies: replies);
        if (plan.calls.length > 10) {
          return AgentRun(instruction: text, results: results,
            replies: replies, error: 'The plan has too many steps.');
        }
        final ran = await runCalls(plan.calls, tools);
        results.addAll(ran.map((r) => r.$2));
        if (generation != _generation) {
          return AgentRun(instruction: text, results: results,
            replies: replies, error: 'Interrupted by stop.');
        }
        if (ran.any((r) => !r.$2.ok)) return AgentRun(instruction: text, results: results, replies: replies);
        plan = await backend.continueWith(ran);
      }
      return AgentRun(instruction: text, results: results, replies: replies,
        error: 'Gave up after too many planning rounds.');
    } catch (e) {
      return AgentRun(instruction: text, results: results, replies: replies, error: '$e');
    } finally {
      if (_ranNow.isNotEmpty) _ranBefore = _ranNow;
      busy = false;
    }
  }

  /// Carries out [instruction] for the fleet, then each robot that took part keeps a line about its own
  /// part in its memory.
  Future<AgentRun> handle(String instruction) async {
    final run = await _handle(instruction);
    for (final entry in _agents.entries) {
      final mine = [for (final r in run.results) if (r.message.startsWith('${entry.key}:')) r];
      if (mine.isEmpty) continue;
      try {
        await RobotAgent.rememberRun(entry.value.memory,
            AgentRun(instruction: run.instruction, results: mine, error: run.error), prefix: '(fleet) ');
      } catch (_) {
        // Memory never turns a done command into an error.
      }
    }
    return run;
  }

  /// Runs [calls] in order of the fleet's own steps (save or run a routine), and between them every run
  /// of robot calls as one batch: each batch is checked in full before any robot starts, then each robot
  /// works through its calls in order while different robots work at the same time.
  Future<List<(SkillCall, SkillResult)>> runCalls(List<SkillCall> calls, AgentManifest tools,
      {bool record = true}) async {
    final out = <(SkillCall, SkillResult)>[];
    var batch = <SkillCall>[];
    Future<bool> flush() async {
      if (batch.isEmpty) return true;
      final ran = await _runBatch(batch, tools, record: record);
      batch = [];
      out.addAll(ran);
      return ran.every((r) => r.$2.ok);
    }
    for (final call in calls) {
      if (!AgentManifest.fleetRoutineSkills.contains(call.name)) {
        batch.add(call);
        continue;
      }
      if (!await flush()) return out;
      final check = validateCall(call, tools);
      final result = !check.ok ? SkillResult.failed(check.rejection!)
          : call.name == 'save_routine' ? await _saveRoutine('${check.call!.args['name']}')
          : await _runRoutineByName('${check.call!.args['name']}', tools);
      out.add((call, result));
      if (!result.ok) return out;
    }
    await flush();
    return out;
  }

  Future<List<(SkillCall, SkillResult)>> _runBatch(List<SkillCall> calls, AgentManifest tools,
      {required bool record}) async {
    final prepared = <(String, SkillCall)>[];
    for (final call in calls) {
      final fleetCheck = validateCall(call, tools);
      if (!fleetCheck.ok) return [(call, SkillResult.failed(fleetCheck.rejection!))];
      final robot = fleetCheck.call!.args['robot'] as String;
      final args = Map<String, Object?>.from(fleetCheck.call!.args)..remove('robot');
      final localCall = SkillCall(call.name, args, call.id);
      final localCheck = validateCall(localCall, _agents[robot]!.manifest());
      if (!localCheck.ok) return [(call, SkillResult.failed('$robot: ${localCheck.rejection}'))];
      prepared.add((robot, localCheck.call!));
    }
    final output = List<SkillResult?>.filled(calls.length, null);
    await Future.wait(_agents.keys.map((robot) async {
      var failed = false;
      for (var i = 0; i < prepared.length; i++) {
        if (prepared[i].$1 != robot) continue;
        if (failed) {
          output[i] = SkillResult.failed('$robot: skipped after a failed step.');
          continue;
        }
        final result = (await _agents[robot]!.runCalls([prepared[i].$2])).single;
        output[i] = SkillResult(result.ok, '$robot: ${result.message}', result.data,
          result.image, result.imageType);
        failed = !result.ok;
      }
    }));
    if (record) {
      for (var i = 0; i < calls.length; i++) {
        if (output[i]!.ok && !_notSaved.contains(calls[i].name)) {
          _ranNow.add(SkillCall(calls[i].name, {'robot': prepared[i].$1, ...prepared[i].$2.args}));
        }
      }
    }
    return [for (var i = 0; i < calls.length; i++) (calls[i], output[i]!)];
  }

  Future<SkillResult> _saveRoutine(String name) async {
    final book = routines;
    if (book == null) return SkillResult.failed('Fleet routines cannot be saved here.');
    final steps = _ranNow.isNotEmpty ? _ranNow : _ranBefore;
    if (steps.isEmpty) return SkillResult.failed('Nothing to save yet: have the robots do something first.');
    try {
      if (!book.loaded) await book.load();
      final existing = book.find(name);
      final saved = await book.save(Routine(id: existing?.id ?? RoutineBook.newId(), name: name,
          steps: [for (final c in steps) RoutineStep.call(c)], schedules: existing?.schedules ?? const [],
          repeat: existing?.repeat ?? 1, pauseSeconds: existing?.pauseSeconds ?? 0));
      final robots = {for (final c in steps) c.args['robot']}.join(', ');
      return SkillResult(true, 'Saved fleet routine "${saved.name}" with ${steps.length} steps for $robots.');
    } on RoutineError catch (e) {
      return SkillResult.failed(e.message);
    }
  }

  Future<SkillResult> _runRoutineByName(String name, AgentManifest tools) async {
    final routine = routines?.find(name);
    if (routine == null) return SkillResult.failed('There is no fleet routine called "$name".');
    return _runRoutineOnce(routine, tools);
  }

  Future<SkillResult> _runRoutineOnce(Routine routine, AgentManifest tools) async {
    final List<SkillCall> calls;
    try {
      calls = routines!.expand(routine);
    } on RoutineError catch (e) {
      return SkillResult.failed('Cannot run "${routine.name}": ${e.message}');
    }
    if (calls.isEmpty) return SkillResult.failed('"${routine.name}" has no steps.');
    final ran = await runCalls(calls, tools, record: false);
    final failed = ran.where((r) => !r.$2.ok).firstOrNull;
    if (failed != null) return SkillResult.failed('"${routine.name}" stopped: ${failed.$2.message}');
    return SkillResult(true, 'Ran fleet routine "${routine.name}" (${calls.length} steps).');
  }

  /// Runs a saved fleet routine without a model (from the screen): [Routine.repeat] rounds with
  /// [Routine.pauseSeconds] between them; a stop ends it at once, a failed step ends the run.
  Future<AgentRun> runRoutine(Routine routine) async {
    final text = 'Run fleet routine "${routine.name}"';
    if (busy) return AgentRun(instruction: text, error: 'The fleet is still working.');
    busy = true;
    final generation = _generation;
    final results = <SkillResult>[];
    try {
      final tools = await manifest();
      final rounds = routine.repeat.clamp(0, Routine.maxRepeat);
      var pause = Duration(seconds: routine.pauseSeconds);
      if (rounds == 0 && pause < RobotAgent.minUntilStoppedPause) pause = RobotAgent.minUntilStoppedPause;
      for (var round = 1; rounds == 0 || round <= rounds; round++) {
        if (round > 1) {
          final until = DateTime.now().add(pause);
          while (DateTime.now().isBefore(until) && generation == _generation) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
        if (generation != _generation) break;
        final r = await _runRoutineOnce(routine, tools);
        results.add(r);
        if (results.length > 20) results.removeAt(0);
        if (generation != _generation || !r.ok) break;
      }
      if (generation != _generation) return AgentRun(instruction: text, results: results, error: 'Interrupted by stop.');
      return AgentRun(instruction: text, results: results);
    } catch (e) {
      return AgentRun(instruction: text, results: results, error: '$e');
    } finally {
      busy = false;
    }
  }

  void stop() {
    _generation++;
    for (final agent in _agents.values) { agent.stop(); }
  }

  void dispose() {
    for (final agent in _agents.values) {
      agent.dispose();
      agent.log.dispose();
    }
  }
}

class _NoPlanner extends AgentBackend {
  @override
  String get name => 'fleet';

  @override
  Future<AgentPlan> plan(AgentRequest request) async => const AgentPlan();
}
