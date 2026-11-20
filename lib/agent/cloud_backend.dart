import 'dart:convert';
import 'package:http/http.dart' as http;
import 'agent.dart';
import 'manifest.dart';
import 'skill.dart';

/// Plans with a cloud model through the developer proxy (tool/agent_proxy.py), which holds the API key
/// and calls Claude (official SDK) or Gemini (REST). The app always sends the conversation in Messages
/// API form (system, tools, messages) and gets back content blocks in that form; the proxy translates
/// for Gemini and fixes the model and limits. Block types the app does not know (such as Gemini's raw
/// parts) are kept in the history and sent back untouched.
///
/// Skills are offered as tools. The model answers with tool_use blocks; the agent validates and runs
/// them and the outcomes go back as tool_result blocks, until the model replies with text only.
class CloudBackend extends AgentBackend {
  CloudBackend({required this.endpoint, this.token = '', http.Client? client,
      this.timeout = const Duration(seconds: 60)})
      : _http = client ?? http.Client();

  /// The proxy's plan URL, e.g. http://192.168.0.29:8787/v1/plan.
  final Uri endpoint;
  /// Shared secret the proxy expects in the X-Proxy-Token header ('' when it has none).
  final String token;
  final Duration timeout;
  final http.Client _http;

  @override
  String get name => 'cloud';

  String _system = '';
  List<Map<String, Object?>> _tools = const [];
  final List<Map<String, Object?>> _messages = [];

  @override
  Future<AgentPlan> plan(AgentRequest request) {
    _system = systemPrompt(request.manifest);
    _tools = request.manifest.toTools();
    _messages
      ..clear()
      ..add({'role': 'user', 'content': '${statusLine(request.status)}\n\n${request.instruction}'});
    return _ask();
  }

  @override
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) {
    _messages.add({
      'role': 'user',
      'content': [
        for (final (call, result) in results)
          {
            'type': 'tool_result',
            'tool_use_id': call.id,
            // A picture (from `look`) goes in the result itself, next to the text.
            'content': result.image == null
                ? jsonEncode(result.toJson())
                : [
                    {'type': 'text', 'text': jsonEncode(result.toJson())},
                    {'type': 'image', 'source': {'type': 'base64', 'media_type': result.imageType ?? 'image/jpeg',
                      'data': base64Encode(result.image!)}},
                  ],
            if (!result.ok) 'is_error': true,
          },
      ],
    });
    return _ask();
  }

  Future<AgentPlan> _ask() async {
    final response = await _http
        .post(endpoint,
            headers: {'content-type': 'application/json', if (token.isNotEmpty) 'x-proxy-token': token},
            body: jsonEncode({'system': _system, 'tools': _tools, 'messages': _messages}))
        .timeout(timeout);
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw StateError('Proxy answered HTTP ${response.statusCode} without JSON.');
    }
    if (body is! Map) throw StateError('Proxy answered HTTP ${response.statusCode} with an unexpected body.');
    if (response.statusCode != 200 || body['error'] != null) {
      throw StateError('${body['error'] ?? 'HTTP ${response.statusCode}'}');
    }
    final content = body['content'];
    if (content is! List) throw StateError('Proxy response has no content.');
    // Keep the assistant turn exactly as returned (thinking blocks included): the next request must
    // carry them unchanged.
    _messages.add({'role': 'assistant', 'content': content});

    final texts = <String>[];
    final calls = <SkillCall>[];
    for (final block in content) {
      if (block is! Map) continue;
      switch (block['type']) {
        case 'text':
          final t = '${block['text'] ?? ''}'.trim();
          if (t.isNotEmpty) texts.add(t);
        case 'tool_use':
          final call = SkillCall.fromJson({'id': block['id'], 'name': block['name'], 'input': block['input']});
          if (call != null) calls.add(call);
      }
    }
    final stop = body['stop_reason'];
    if (stop == 'refusal') {
      return AgentPlan(reply: texts.isEmpty ? 'The model declined this request.' : texts.join('\n'));
    }
    if (stop == 'max_tokens' && calls.isNotEmpty) {
      // A tool call cut off by the token limit may be incomplete: do not run it.
      throw StateError('The model response was cut off before its tool calls were complete.');
    }
    return AgentPlan(calls: stop == 'tool_use' || calls.isNotEmpty ? calls : const [], reply: texts.join('\n'));
  }

  /// Instructions for the model. Stable for a robot, so the proxy's prompt cache can reuse it.
  static String systemPrompt(AgentManifest manifest) => '''
You are the assistant inside Mobile ROS, a phone app that controls a ROS robot. The person types
instructions in any natural language. Reply in the person's language while preserving robot and place names.

${manifest.describe()}

How to act:
- Move the robot only through the tools. Each tool call is checked by the app before anything moves,
  and its result (ok or failed, with a message) comes back to you.
- Break a request into steps and call one tool at a time when later steps depend on earlier results.
- Distances are in metres, angles in degrees; positive angles turn left. Use the slow speed unless the
  person asks for faster.
- If a request is unclear, unsafe, or cannot be done with the tools, do not guess: say so in one short
  sentence and suggest what you can do instead.
- If a step fails, stop and explain briefly; do not retry on your own.
- When the person says how to call them, names the robot, or asks you to remember something, save it
  with the profile or memory tool when you have one${manifest.skill('update_profile') == null ? '' :
  ' (how to call them: update_profile with field call_person)'}, in any language. Only saying that you
  will remember does not keep it.
- Never say that the robot does something without calling the tool that does it.
- Questions the robot status already answers (battery, motion) need no tool: answer from the status.
- Reply in the person's language, in one or two short sentences. No markdown.''';

  /// The robot's state, put in the user turn (not the system prompt) so the system prompt stays cacheable.
  static String statusLine(Map<String, Object?> status) => 'Robot status: ${jsonEncode(status)}';
}
