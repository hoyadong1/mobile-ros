import 'dart:convert';

import '../memory.dart';
import 'learned_tools.dart';
import 'manifest.dart';
import 'skill.dart';
import 'validator.dart';

/// How the assistant learns from one person and one robot: habits become tools, the person's own words
/// for things are kept, and the online model may define tools of its own. Everything learned is data in
/// the robot's (or the person's) [Memory] and passes the same validation as any other call when it runs.
class Learning {
  const Learning._();

  /// The same actions this many times (in different requests) become a learned tool.
  static const habitAfter = 3;
  /// Kind of the person's own words for things ("거기" = 부엌), in the person's memory.
  static const aliasKind = 'alias';

  /// Skills never replayed in a habit (they change memory or only read the robot).
  static const notLearned = {'stop', 'get_status', 'look', 'save_routine', 'run_routine', 'cancel_navigation',
    'check_robot', 'save_place', 'save_map', 'update_profile', 'remember', 'define_tool', 'learn_phrase'};

  /// After a request carried out [calls]: keeps them with the episode's data, and when the same calls
  /// were made [habitAfter] times, makes (or extends) a habit tool with [instruction] as one of its phrasings.
  /// Returns the tool that was made or extended, if any.
  static Future<LearnedTool?> observe(Memory robot, String instruction, List<SkillCall> calls) async {
    // A learned tool asked for in new words: those words become one of its phrasings.
    if (calls.length == 1 && calls.single.name.startsWith(LearnedTool.prefix)) {
      final item = robot.item(LearnedTool.kind, calls.single.name);
      final tool = LearnedTool.fromJson(item?.data);
      final phrase = instruction.trim();
      if (tool == null || phrase.isEmpty || tool.phrases.any((p) => normalize(p) == normalize(phrase))) return null;
      final phrases = [...tool.phrases, phrase];
      final updated = LearnedTool(name: tool.name, description: tool.description, steps: tool.steps, params: tool.params,
          origin: tool.origin, signature: tool.signature,
          phrases: phrases.length > LearnedTool.maxPhrases ? phrases.sublist(phrases.length - LearnedTool.maxPhrases) : phrases);
      await LearnedTool.save(robot, updated);
      return updated;
    }
    final kept = [for (final c in calls) if (!notLearned.contains(c.name) && !c.name.startsWith(LearnedTool.prefix)) c];
    if (kept.isEmpty || kept.length > LearnedTool.maxSteps || kept.length != calls.length) return null;
    final signature = LearnedTool.signatureOf(kept);
    final times = robot.ofKind('episode').where((e) => e.data?['sig'] == signature).length;
    final existing = [
      for (final i in robot.ofKind(LearnedTool.kind)) if (LearnedTool.fromJson(i.data) case final t? when t.signature == signature) t,
    ].firstOrNull;
    final phrase = instruction.trim();
    if (existing != null) {
      if (phrase.isEmpty || existing.phrases.any((p) => normalize(p) == normalize(phrase))) return null;
      final phrases = [...existing.phrases, phrase];
      final updated = LearnedTool(name: existing.name, description: existing.description, steps: existing.steps,
          params: existing.params, origin: existing.origin, signature: signature,
          phrases: phrases.length > LearnedTool.maxPhrases ? phrases.sublist(phrases.length - LearnedTool.maxPhrases) : phrases);
      await LearnedTool.save(robot, updated);
      return updated;
    }
    if (times < habitAfter) return null;
    final phrases = <String>[];
    for (final e in robot.ofKind('episode').toList().reversed) {
      final said = e.data?['say'];
      if (e.data?['sig'] == signature && said is String && !phrases.any((p) => normalize(p) == normalize(said))) {
        phrases.add(said);
      }
      if (phrases.length >= LearnedTool.maxPhrases) break;
    }
    final n = robot.ofKind(LearnedTool.kind).where((i) => i.key?.startsWith('${LearnedTool.prefix}usual_') == true).length + 1;
    final tool = LearnedTool(name: '${LearnedTool.prefix}usual_$n', origin: 'habit', signature: signature, steps: kept,
        phrases: phrases.reversed.toList(),
        description: 'What the person often asks this robot for (${kept.map(_short).join(', then ')}).');
    await LearnedTool.save(robot, tool);
    return tool;
  }

  static String _short(SkillCall c) => '${c.name}(${c.args.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';

  /// For matching phrasings: lower case, no punctuation or spaces.
  static String normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s.,!?~。、]+'), '');

  static final _usual = RegExp(r'평소처럼|평소대로|늘 하던|하던 대로|하던대로|맨날 하던|\bthe usual\b|\bas usual\b|\bsame as always\b',
      caseSensitive: false);

  /// The learned tool [instruction] asks for, found without a model: it is one of a tool's phrasings, or it
  /// says "as usual" and one habit is the most used. Null when none (or the tool takes parameters).
  static SkillCall? directCall(String instruction, List<LearnedTool> tools) {
    final said = normalize(instruction);
    if (said.isEmpty) return null;
    final plain = [for (final t in tools) if (t.params.every((p) => !p.required)) t];
    for (final t in plain) {
      if (t.phrases.any((p) => normalize(p) == said)) return SkillCall(t.name, const {});
    }
    if (_usual.hasMatch(instruction)) {
      // Only when there is one habit: with several, "as usual" is the online model's (or the person's) call.
      final habits = [for (final t in plain) if (t.origin == 'habit') t];
      if (habits.length == 1) return SkillCall(habits.single.name, const {});
    }
    return null;
  }

  /// Why [phrase] may not stand for [meaning], or null. A phrase of one letter, a number or a common robot
  /// word would rewrite every request ("가" in "앞으로 가"), so those are not learned.
  static String? unsafePhrase(String phrase, String meaning) {
    final p = phrase.trim();
    if (p.runes.length < 2) return 'A phrase needs at least two letters.';
    if (RegExp(r'^[\d\s.,]+$').hasMatch(p)) return 'A number cannot be a phrase.';
    if (RegExp(r'^(앞으로|뒤로|왼쪽|오른쪽|멈춰|정지|가|돌아|forward|back|backward|left|right|stop|go|turn)$', caseSensitive: false)
        .hasMatch(p)) {
      return '"$p" is a word for moving; it cannot mean something else.';
    }
    if (p.toLowerCase() == meaning.trim().toLowerCase()) return 'The phrase and its meaning are the same.';
    return null;
  }

  /// [instruction] with the person's own words replaced by what they mean, longest first.
  static String rewrite(String instruction, Map<String, String> aliases) {
    var out = instruction;
    for (final phrase in aliases.keys.toList()..sort((a, b) => b.length.compareTo(a.length))) {
      if (phrase.trim().isEmpty) continue;
      out = out.replaceAll(RegExp(RegExp.escape(phrase), caseSensitive: false), aliases[phrase]!);
    }
    return out;
  }

  /// Work records beyond [keep] + [batch] are folded, oldest [batch] at a time, into one summary line per
  /// day ("2026-11-17 summary of 12 requests: \"앞으로 20센티 가\" x3 done; ..."). By rule, not a model, so
  /// it costs nothing and works offline. Returns how many records were folded.
  static Future<int> compact(Memory robot, {int keep = 40, int batch = 20}) async {
    final all = robot.ofKind('episode').where((e) => e.data?['summary'] != true).toList()
      ..sort((a, b) => a.created.compareTo(b.created));
    if (all.length <= keep + batch) return 0;
    final old = all.take(batch).toList();
    final days = <String, List<MemoryItem>>{};
    for (final e in old) {
      days.putIfAbsent(e.created.toIso8601String().substring(0, 10), () => []).add(e);
    }
    for (final MapEntry(key: day, value: items) in days.entries) {
      final counts = <String, (int, int)>{}; // request -> (done, not done)
      for (final e in items) {
        final m = RegExp(r'"(.*?)" -> (.*)$').firstMatch(e.text);
        if (m == null) continue;
        final (ok, bad) = counts[m[1]!] ?? (0, 0);
        counts[m[1]!] = m[2]!.startsWith('Not done') ? (ok, bad + 1) : (ok + 1, bad);
      }
      final parts = [
        for (final e in counts.entries.toList()..sort((a, b) => (b.value.$1 + b.value.$2).compareTo(a.value.$1 + a.value.$2)))
          '"${e.key}" x${e.value.$1 + e.value.$2}${e.value.$2 == 0 ? '' : ' (${e.value.$2} not done)'}',
      ];
      await robot.add('episode', '$day summary of ${items.length} requests: ${parts.join('; ')}', source: 'app',
          data: const {'summary': true}, at: items.first.created);
    }
    await robot.removeAll(old.map((e) => e.id));
    return old.length;
  }

  /// Whether every step of [tool] (with example arguments) is something the robot of [m] can do.
  static String? fits(LearnedTool tool, AgentManifest m) {
    final example = {
      for (final p in tool.params) p.name: p.type == ParamType.number
          ? ((p.min ?? 0) + (p.max ?? p.min ?? 1)) / 2 : (p.values?.firstOrNull ?? 'x'),
    };
    for (final step in tool.expand(example)) {
      final check = validateCall(step, m);
      if (!check.ok) return '${step.name}: ${check.rejection}';
    }
    return null;
  }

  /// Copies [tool] to other robots of the same person (the person chose to): only to those whose own
  /// skills can do every step, and not over a tool of the same name there. Returns who got it and who
  /// could not take it (with why).
  static Future<({List<String> shared, Map<String, String> refused})> share(LearnedTool tool,
      Map<String, (Memory, AgentManifest)> robots) async {
    final shared = <String>[], refused = <String, String>{};
    for (final MapEntry(key: name, value: (memory, manifest)) in robots.entries) {
      await memory.load();
      final why = memory.item(LearnedTool.kind, tool.name) != null ? 'already has it' : fits(tool, manifest);
      if (why != null) {
        refused[name] = why;
        continue;
      }
      await LearnedTool.save(memory, tool);
      shared.add(name);
    }
    return (shared: shared, refused: refused);
  }

  /// The person's own words, from their memory: phrase -> meaning.
  static Map<String, String> aliases(Memory person) => {
    for (final i in person.ofKind(aliasKind)) if (i.key != null && unsafePhrase(i.key!, i.text) == null) i.key!: i.text,
  };

  /// A tool the online model defines (`define_tool`): checked against what this robot can do (each step a
  /// built-in skill of [m] that passes validation with example values) before it is kept.
  static ({LearnedTool? tool, String? error}) define(Map<String, Object?> args, AgentManifest m) {
    final name = LearnedTool.nameFrom('${args['name'] ?? ''}');
    final description = '${args['description'] ?? ''}'.trim();
    if (description.isEmpty) return (tool: null, error: 'Say what the tool is for.');
    List<Object?> list(Object? v) {
      if (v is List) return v;
      if (v is String && v.trim().isNotEmpty) {
        final d = jsonDecode(v);
        if (d is List) return d;
      }
      return const [];
    }
    try {
      final tool = LearnedTool.fromJson({'name': name, 'description': description, 'origin': 'assistant',
          'steps': list(args['steps']), 'params': list(args['parameters'])});
      if (tool == null) return (tool: null, error: 'The steps must be a list of {"skill": ..., arguments...}.');
      final example = {
        for (final p in tool.params) p.name: p.type == ParamType.number
            ? ((p.min ?? 0) + (p.max ?? p.min ?? 1)) / 2 : (p.values?.firstOrNull ?? 'x'),
      };
      for (final step in tool.expand(example)) {
        if (step.name.startsWith(LearnedTool.prefix) || notLearned.contains(step.name)) {
          return (tool: null, error: '"${step.name}" cannot be a step of a tool.');
        }
        final check = validateCall(step, m);
        if (!check.ok) return (tool: null, error: 'Step ${step.name}: ${check.rejection}');
      }
      return (tool: tool, error: null);
    } on FormatException catch (e) {
      return (tool: null, error: 'The steps are not valid JSON: ${e.message}');
    }
  }
}
