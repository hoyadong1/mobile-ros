import 'dart:convert';

import '../memory.dart';
import 'skill.dart';

/// A tool the assistant learned for one person and robot: a named, described sequence of the robot's own
/// skills, possibly with parameters. Given to the model as a function like any other, never shown to the
/// person as such. It is data, not code: every step is validated again for the robot when it runs, so a
/// learned tool can do nothing a plain instruction could not.
///
/// Learned two ways: from habit (the same actions asked for three times become `my_usual_N`, with the
/// person's own phrasings) or by the online assistant (`define_tool`). Kept in the robot's [Memory] as
/// kind [kind], keyed by name.
class LearnedTool {
  const LearnedTool({required this.name, required this.description, this.params = const [], required this.steps,
      this.phrases = const [], this.origin = 'assistant', this.signature});

  static const kind = 'tool';
  /// Every learned tool's name starts with this, so it never takes a built-in skill's name.
  static const prefix = 'my_';
  static const maxSteps = 20, maxPhrases = 8;

  final String name;
  /// When to use it, for the model.
  final String description;
  final List<SkillParam> params;
  /// The steps; a string argument `{p}` is replaced by parameter p (a whole `{p}` keeps its type).
  final List<SkillCall> steps;
  /// What the person said when they asked for it (habits): matched directly by the on-device assistant.
  final List<String> phrases;
  /// `habit` or `assistant`.
  final String origin;
  /// For habits: the steps as JSON, to recognise the same actions again.
  final String? signature;

  Skill toSkill() => Skill(name, [
        description,
        if (phrases.isNotEmpty) 'The person has said it as: ${phrases.map((p) => '"$p"').join(', ')}.',
        'Prefer this whenever the request matches.',
      ].join(' '), params: params);

  /// The steps with [args] filled in.
  List<SkillCall> expand(Map<String, Object?> args) {
    Object? fill(Object? v) {
      if (v is String) {
        final whole = RegExp(r'^\{(\w+)\}$').firstMatch(v);
        if (whole != null && args.containsKey(whole[1])) return args[whole[1]];
        return v.replaceAllMapped(RegExp(r'\{(\w+)\}'), (m) => args.containsKey(m[1]) ? '${args[m[1]]}' : m[0]!);
      }
      if (v is Map) return {for (final e in v.entries) e.key: fill(e.value)};
      if (v is List) return [for (final x in v) fill(x)];
      return v;
    }
    return [for (final s in steps) SkillCall(s.name, {for (final e in s.args.entries) e.key: fill(e.value)})];
  }

  /// "Night patrol!" -> "my_night_patrol"; letters other than a-z become "_" (function names must be ASCII).
  static String nameFrom(String raw) {
    var n = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
    if (n.startsWith(prefix)) n = n.substring(prefix.length);
    if (n.isEmpty) n = 'tool';
    if (n.length > 40) n = n.substring(0, 40);
    return '$prefix$n';
  }

  Map<String, Object?> toJson() => {
    'name': name, 'description': description, 'origin': origin,
    if (params.isNotEmpty) 'params': [for (final p in params) _paramJson(p)],
    'steps': [for (final s in steps) {'skill': s.name, ...s.args}],
    if (phrases.isNotEmpty) 'phrases': phrases,
    'signature': ?signature,
  };

  static LearnedTool? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'], description = j['description'], steps = j['steps'];
    if (name is! String || !name.startsWith(prefix) || description is! String || steps is! List || steps.isEmpty) return null;
    final calls = <SkillCall>[];
    for (final s in steps.take(maxSteps)) {
      if (s is! Map || s['skill'] is! String) return null;
      calls.add(SkillCall(s['skill'] as String, {for (final e in s.entries) if (e.key != 'skill') '${e.key}': e.value}));
    }
    final params = j['params'], phrases = j['phrases'];
    return LearnedTool(name: name, description: description, steps: calls,
        params: [if (params is List) for (final p in params) ?_paramFrom(p)],
        phrases: [if (phrases is List) for (final p in phrases.take(maxPhrases)) if (p is String) p],
        origin: j['origin'] is String ? j['origin'] as String : 'assistant',
        signature: j['signature'] is String ? j['signature'] as String : null);
  }

  static Map<String, Object?> _paramJson(SkillParam p) => {
    'name': p.name, 'type': p.type.name, 'description': p.description,
    if (!p.required) 'required': false, 'min': ?p.min, 'max': ?p.max, 'values': ?p.values, 'unit': ?p.unit,
  };

  static SkillParam? _paramFrom(Object? j) {
    if (j is! Map || j['name'] is! String || !RegExp(r'^\w{1,30}$').hasMatch(j['name'] as String)) return null;
    final type = j['type'] == 'number' ? ParamType.number : ParamType.string;
    num? n(Object? v) => v is num ? v : null;
    final values = j['values'];
    return SkillParam(j['name'] as String, type, j['description'] is String ? j['description'] as String : '',
        required: j['required'] != false, min: n(j['min'])?.toDouble(), max: n(j['max'])?.toDouble(),
        values: values is List ? [for (final v in values) '$v'] : null, unit: j['unit'] is String ? j['unit'] as String : null);
  }

  /// The learned tools in [memory], those most relevant to [query] first (at most [limit]).
  static List<LearnedTool> from(Memory memory, {String query = '', int limit = 8}) => [
    for (final item in memory.relevant(query, kinds: const {kind}, budget: 1 << 30).take(limit))
      ?LearnedTool.fromJson(item.data),
  ];

  /// Keeps [tool] in [memory] (replacing one of the same name).
  static Future<void> save(Memory memory, LearnedTool tool) => memory.put(kind, tool.name,
      '${tool.description} ${tool.phrases.join(' ')}', data: tool.toJson(), source: tool.origin == 'habit' ? 'app' : 'assistant');

  /// The same actions as JSON (what makes two requests "the same thing").
  /// Numbers count as equal whatever their spelling (a model writes 30 one time and 30.0 the next), and
  /// arguments in any order.
  static String signatureOf(List<SkillCall> calls) {
    Object? norm(Object? v) => v is num ? (v * 1000).round() / 1000 : v;
    return jsonEncode([
      for (final c in calls) {'skill': c.name, for (final k in (c.args.keys.toList()..sort())) k: norm(c.args[k])},
    ]);
  }
}
