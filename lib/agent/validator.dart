import 'manifest.dart';
import 'skill.dart';

/// The outcome of checking one [SkillCall] before anything moves.
class Verdict {
  const Verdict.accepted(SkillCall this.call, [this.notes = const []]) : rejection = null;
  const Verdict.rejected(String this.rejection) : call = null, notes = const [];

  /// The call with normalised arguments (numbers as doubles, defaults filled, values clamped).
  final SkillCall? call;
  /// What was changed, e.g. a distance clamped to the limit. Shown to the person and the model.
  final List<String> notes;
  final String? rejection;

  bool get ok => call != null;

  @override
  String toString() => ok ? 'accepted ${call!}${notes.isEmpty ? '' : ' (${notes.join('; ')})'}' : 'rejected: $rejection';
}

/// Checks a model's call against the manifest: the skill must be offered, required arguments present,
/// no unknown arguments, numbers finite and within range (clamped, with a note), strings from the
/// allowed set. Nothing a model writes reaches the robot without passing here.
Verdict validateCall(SkillCall call, AgentManifest manifest) {
  final skill = manifest.skill(call.name);
  if (skill == null) {
    return Verdict.rejected('"${call.name}" is not available on this robot. '
        'Available: ${manifest.skills.map((s) => s.name).join(', ')}.');
  }
  final unknown = call.args.keys.where((k) => skill.param(k) == null).toList();
  if (unknown.isNotEmpty) {
    return Verdict.rejected('${skill.name} does not take ${unknown.join(', ')}.');
  }
  final args = <String, Object?>{};
  final notes = <String>[];
  for (final p in skill.params) {
    final raw = call.args[p.name];
    if (raw == null) {
      if (p.required) return Verdict.rejected('${skill.name} needs ${p.name}.');
      if (p.values != null && p.values!.isNotEmpty) args[p.name] = p.values!.first; // e.g. speed: slow
      continue;
    }
    switch (p.type) {
      case ParamType.number:
        final n = raw is num ? raw.toDouble() : raw is String ? double.tryParse(raw.trim()) : null;
        if (n == null || !n.isFinite) return Verdict.rejected('${p.name} must be a number, got "$raw".');
        var v = n;
        if (p.min != null && v < p.min!) v = p.min!;
        if (p.max != null && v > p.max!) v = p.max!;
        if (v != n) notes.add('${p.name} $n limited to $v${p.unit == null ? '' : ' ${p.unit}'}');
        args[p.name] = v;
      case ParamType.string:
        final s = '$raw'.trim();
        final allowed = p.values;
        if (allowed != null) {
          final match = allowed.where((a) => a.toLowerCase() == s.toLowerCase()).firstOrNull;
          if (match == null) return Verdict.rejected('${p.name} must be one of ${allowed.join(', ')}, got "$s".');
          args[p.name] = match;
        } else {
          args[p.name] = s;
        }
    }
  }
  return Verdict.accepted(SkillCall(skill.name, args, call.id), notes);
}
