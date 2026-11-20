import 'agent.dart';
import 'local/fleet_local_backend.dart';
import 'local/local_backend.dart';
import 'route_policy.dart';
import 'voice.dart';
import 'skill.dart';
import 'validator.dart';
import 'instruction_language.dart';

/// Which model handled the last instruction. For tests and diagnostics; the person only sees "the
/// assistant".
enum Route { local, cloud, none }

/// One assistant made of two models: the on-device one for what it can do (short, simple commands,
/// offline, free) and the cloud one for the rest (seeing through the camera, multi-step requests,
/// anything the small model hands off or gets wrong).
///
/// For each instruction: requests that clearly need the cloud go there directly; otherwise the local
/// model plans first, and its plan is used only if it did not hand off and every call passes the
/// validator. Otherwise the cloud plans, when [cloudAllowed] says this request may use it (plan tier,
/// daily quota). Without the cloud, a local refusal is answered in words and nothing moves.
class RouterBackend extends AgentBackend {
  RouterBackend({this.local, this.cloud, bool Function()? cloudAllowed, this.onCloudUse})
      : cloudAllowed = cloudAllowed ?? (() => true);

  final AgentBackend? local;
  final AgentBackend? cloud;
  /// Checked before each cloud request (subscription, quota).
  final bool Function() cloudAllowed;
  /// Called when an instruction goes to the cloud (to count it against a quota).
  final void Function()? onCloudUse;

  AgentBackend? _active;
  Route _route = Route.none;
  Route get lastRoute => _route;

  @override
  String get name => 'assistant';

  /// Why the last instruction went where it did (see [RoutePolicy]).
  RouteDecision? lastDecision;

  bool _cloudReady() => cloud != null && cloudAllowed();

  /// For a fleet, a sentence of several robots' parts in another language ("robot1 avanza 50 cm, robot2
  /// gira a la derecha") is judged part by part, as the fleet planner plans it: each part with that robot.
  static RouteDecision _decide(AgentRequest request) {
    final whole = RoutePolicy.decide(request.instruction, request.manifest);
    if (whole.handler == Handler.local || request.robots.length < 2 ||
        !const {'needs language-aware interpretation', 'too many steps for the on-device model'}.contains(whole.reason)) {
      return whole;
    }
    if (isFleetStop(request.instruction)) return const RouteDecision(Handler.local, 'a direct robot command');
    final split = splitByRobot(request.instruction, request.robots.keys.toList(), aliases: request.manifest.fleetAliases);
    if (split.unknown.isNotEmpty) return const RouteDecision(Handler.local, 'a robot that is not in the fleet');
    if (split.parts.isEmpty) return whole;
    for (final (names, text) in split.parts) {
      if (RobotAgent.isStopWord(text)) continue;
      final part = RoutePolicy.decide(text, request.robots[names.first]!);
      if (part.handler == Handler.cloud) return part;
    }
    return const RouteDecision(Handler.local, 'a direct robot command');
  }

  @override
  Future<AgentPlan> plan(AgentRequest request) async {
    _active = null;
    _route = Route.none;
    // Remembering what the person says is always the phone's job (fixed patterns, no model).
    final remembering = memoryCall(request.instruction, request.manifest) != null;
    final decision = lastDecision = remembering
        ? const RouteDecision(Handler.local, 'something to remember')
        : _decide(request);
    if (local == null) return _toCloud(request);
    if (decision.handler == Handler.cloud) {
      if (_cloudReady()) return _toCloud(request);
      // No online assistant for this: a plain conversation may still get a word from the small model,
      // but nothing it plans is run; anything else is declined with the reason.
      _route = Route.local;
      _active = local;
      final ko = replyLanguageFor(request.instruction) == ReplyLanguage.ko;
      if (decision.reason == 'needs language-aware interpretation') {
        return AgentPlan(reply: InstructionLanguagePolicy.unavailable(request.instruction, request.manifest));
      }
      if (decision.reason.startsWith('conversation')) {
        try {
          final said = (await local!.plan(request)).reply;
          if (said != null && said.trim().isNotEmpty) return AgentPlan(reply: said);
        } catch (_) {}
      }
      return AgentPlan(reply: ko
          ? '이 요청은 온라인 AI가 필요해요(${_reasonKo(decision.reason)}). 지금은 기기 안 AI만 쓸 수 있어서 하지 않았어요.'
          : 'This needs the online assistant (${decision.reason}). Only the on-device assistant is available, so nothing was done.');
    }

    AgentPlan? localPlan;
    try {
      localPlan = await local!.plan(request);
    } catch (_) {
      if (!_cloudReady()) rethrow;
    }
    if (localPlan != null && _acceptable(localPlan, request)) {
      _active = local;
      _route = Route.local;
      return localPlan;
    }
    if (_cloudReady()) return _toCloud(request);
    _route = Route.local;
    _active = local;
    // No cloud for this request: never run a plan the small model was unsure of.
    return AgentPlan(reply: localPlan is LocalPlan && localPlan.handoff
        ? localPlan.reply ?? 'I cannot handle this request right now. Try a simpler instruction.'
        : localPlan?.reply ?? 'I cannot handle this request right now.');
  }

  static String _reasonKo(String reason) => switch (reason) {
    'needs the camera' => '카메라로 봐야 함',
    'depends on what happens' => '상황에 따라 달라지는 일',
    'needs searching or following' => '찾거나 따라가는 일',
    'conversation, not a robot command' => '대화',
    'too many steps for the on-device model' => '단계가 많음',
    'making or using a tool' => '도구 만들기·쓰기',
    _ => reason,
  };

  bool _acceptable(AgentPlan plan, AgentRequest request) {
    if (plan is LocalPlan && plan.handoff) return false;
    return plan.calls.every((c) => validateCall(c, request.manifest).ok);
  }

  Future<AgentPlan> _toCloud(AgentRequest request) {
    final c = cloud;
    if (c == null || !cloudAllowed()) {
      throw StateError('This request needs the online assistant, which is not available now.');
    }
    _active = c;
    _route = Route.cloud;
    onCloudUse?.call();
    return c.plan(request);
  }

  @override
  Future<AgentPlan> continueWith(List<(SkillCall, SkillResult)> results) =>
      _active?.continueWith(results) ?? Future.value(const AgentPlan());
}
