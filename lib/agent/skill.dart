/// The vocabulary between a language model and the robot: what the robot can do ([Skill]), what the
/// model asks for ([SkillCall]), and what happened ([SkillResult]). Models never see ROS topics; they
/// pick skills, and the app turns skills into ROS messages through the session controllers.
library;

import 'dart:typed_data';

enum ParamType { number, string }

class SkillParam {
  const SkillParam(this.name, this.type, this.description,
      {this.required = true, this.min, this.max, this.values, this.unit});

  final String name;
  final ParamType type;
  final String description;
  final bool required;
  /// Range for numbers. Values outside it are clamped by the validator, which says so in its note.
  final double? min, max;
  /// Allowed strings for an enum-like parameter.
  final List<String>? values;
  final String? unit;

  /// JSON Schema for this parameter (the shape LLM tool definitions use).
  Map<String, Object?> toJsonSchema() => {
    'type': type == ParamType.number ? 'number' : 'string',
    'description': [description, if (unit != null) 'Unit: $unit.',
      if (min != null && max != null) 'Range $min to $max.'].join(' '),
    if (min != null) 'minimum': min,
    if (max != null) 'maximum': max,
    if (values != null) 'enum': values,
  };
}

class Skill {
  const Skill(this.name, this.description, {this.params = const []});

  final String name;
  final String description;
  final List<SkillParam> params;

  SkillParam? param(String name) => params.where((p) => p.name == name).firstOrNull;

  /// A tool definition: {name, description, input_schema}. Claude's tool use takes this shape as is;
  /// other backends adapt it.
  Map<String, Object?> toToolJson() => {
    'name': name,
    'description': description,
    'input_schema': {
      'type': 'object',
      'properties': {for (final p in params) p.name: p.toJsonSchema()},
      'required': [for (final p in params) if (p.required) p.name],
      'additionalProperties': false,
    },
  };
}

/// One skill the model asked for.
class SkillCall {
  const SkillCall(this.name, [this.args = const {}, this.id]);

  final String name;
  final Map<String, Object?> args;
  /// The model's id for this call (a tool_use id), so its result can be matched to it.
  final String? id;

  /// From `{"name": ..., "args": {...}}` (also accepts `input` or `arguments` for the arguments).
  static SkillCall? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final args = json['args'] ?? json['input'] ?? json['arguments'] ?? const {};
    if (name is! String || args is! Map) return null;
    final id = json['id'];
    return SkillCall(name, Map<String, Object?>.from(args), id is String ? id : null);
  }

  Map<String, Object?> toJson() => {'name': name, 'args': args};

  @override
  String toString() => args.isEmpty ? '$name()' : '$name(${args.entries.map((e) => '${e.key}: ${e.value}').join(', ')})';
}

class SkillResult {
  const SkillResult(this.ok, this.message, [this.data = const {}, this.image, this.imageType]);
  const SkillResult.failed(String message, [Map<String, Object?> data = const {}]) : this(false, message, data);

  final bool ok;
  /// One sentence for the person and for the model's next turn.
  final String message;
  final Map<String, Object?> data;
  /// A picture for the model to look at (the `look` skill), encoded as [imageType].
  final Uint8List? image;
  /// `image/jpeg` or `image/png`.
  final String? imageType;

  Map<String, Object?> toJson() => {'ok': ok, 'message': message, if (data.isNotEmpty) 'data': data};

  @override
  String toString() => '${ok ? 'ok' : 'failed'}: $message';
}
