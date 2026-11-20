import 'learned_tools.dart';
import '../robot_persona.dart';
import '../controllers/navigation_controller.dart';
import '../places.dart';
import '../robot_profile.dart';
import 'robot_tools.dart' show RobotAbilities;
import 'skill.dart';

/// Hard limits the validator enforces on every agent command, whatever the model asks for.
class AgentLimits {
  const AgentLimits({this.maxDistance = 2.0, this.maxAngleDeg = 360, this.speedScales = const {
    'slow': 0.3, 'normal': 0.6}});

  /// Longest straight move per call, in metres. Longer trips go through navigation.
  final double maxDistance;
  final double maxAngleDeg;
  /// Fraction of the profile's top speed per named speed. There is deliberately no "fast".
  final Map<String, double> speedScales;
}

/// What this robot can do right now, as skills: ROSClaw's affordance manifest. Built from the robot
/// profile (how the base moves) and the navigation controller (whether goals can be sent), so a skill
/// is offered only when the app can actually carry it out.
class AgentManifest {
  AgentManifest._(this.skills, this.profile, this.canNavigate, this.limits, this.places, this.routines,
      [this.fleetRobots = const [], this.abilities, this.armPoses = const [], this.persona,
      this.fleetPersonas = const {}, this.learned = const [], this.aliases = const {}]);

  /// A fleet tool list: each skill requires a robot name. A robot is offered only for skills its
  /// own manifest supports; execution still validates against that robot's full manifest.
  /// Routines are the fleet's own ([routines], saved with [canSaveRoutines]): each of their steps names its
  /// robot, so running or saving one names no robot. A robot's own routines stay on that robot's screen.
  factory AgentManifest.fleet(Map<String, AgentManifest> robots,
      {List<String> routines = const [], bool canSaveRoutines = false}) {
    final personas = {for (final e in robots.entries) if (e.value.persona != null) e.key: e.value.persona!};
    final bySkill = <String, List<(String, Skill)>>{};
    for (final entry in robots.entries) {
      for (final skill in entry.value.skills) {
        if (fleetRoutineSkills.contains(skill.name)) continue;
        bySkill.putIfAbsent(skill.name, () => []).add((entry.key, skill));
      }
    }
    final skills = <Skill>[
      for (final entry in bySkill.entries)
        Skill(entry.key, '${entry.value.first.$2.description} Specify which robot acts.', params: [
          SkillParam('robot', ParamType.string, 'Robot to perform this action.',
            values: [for (final item in entry.value) item.$1]),
          for (final param in entry.value.first.$2.params)
            if (param.values == null) param else SkillParam(param.name, param.type, param.description,
              required: param.required, min: param.min, max: param.max, unit: param.unit,
              values: {
                for (final item in entry.value)
                  for (final value in item.$2.param(param.name)?.values ?? const <String>[]) value,
              }.toList()),
        ]),
      if (routines.isNotEmpty) Skill('run_routine',
          'Run a fleet routine the person saved, by its name. Each of its steps already says which robot does '
          'it; robots work at the same time. Prefer this whenever the person names a routine.',
          params: [SkillParam('name', ParamType.string, 'The saved fleet routine to run.', values: routines)]),
      if (canSaveRoutines) const Skill('save_routine',
          'Save the robot actions carried out so far in this instruction (or, if none, in the previous one), '
          'with which robot did each, as a fleet routine with this name. Replaces one with the same name.',
          params: [SkillParam('name', ParamType.string, 'Name for the routine, as the person said it.')]),
    ];
    return AgentManifest._(skills, null, false, const AgentLimits(), const [], routines, robots.keys.toList(),
        null, const [], null, personas);
  }

  /// Skills that belong to the fleet, not to one robot, in a fleet tool list.
  static const fleetRoutineSkills = {'run_routine', 'save_routine'};

  factory AgentManifest.build({RobotProfile? profile, NavigationController? nav,
      AgentLimits limits = const AgentLimits(), List<Place> places = const [], List<String> routines = const [],
      bool canSaveRoutines = false, List<String> armPoses = const [], bool hasGripper = false, RobotAbilities? abilities,
      RobotPersona? persona, bool canRemember = false, List<LearnedTool> learned = const [],
      Map<String, String> aliases = const {}}) {
    final drive = profile?.drive;
    final canDrive = drive == DriveType.differential || drive == DriveType.holonomic || drive == DriveType.ackermann;
    final canTurnInPlace = drive == DriveType.differential || drive == DriveType.holonomic;
    // Map navigation is for ground bases: a drone or a fixed arm is never sent to a map point.
    final canNavigate = nav != null && nav.available && canDrive;
    final speed = SkillParam('speed', ParamType.string, 'How fast to go. Use slow unless asked otherwise.',
        required: false, values: limits.speedScales.keys.toList());
    final skills = <Skill>[
      const Skill('stop', 'Stop all motion immediately, including navigation.'),
      const Skill('get_status', 'Report what the robot is doing right now: whether it is moving, and its '
          'navigation goal and progress. Use it for "what are you doing", "where are you going", '
          '"status".'),
      if (profile != null && profile.cameraSource == CameraSource.rosImage && profile.cameraTopic.isNotEmpty)
        const Skill('look',
            "Take a picture with the robot's camera and look at it. Use it to answer questions about what the "
            'robot sees or what is around it, or to check the way before moving. The picture comes back with '
            'the result.'),
      if (canDrive) Skill('move',
          'Drive straight forward (positive) or backward (negative) by a distance, then stop. '
          'Open loop: the distance is approximate.',
          params: [SkillParam('distance_m', ParamType.number, 'Distance to travel; negative goes backward.',
              min: -limits.maxDistance, max: limits.maxDistance, unit: 'm'), speed]),
      if (drive == DriveType.holonomic) Skill('strafe',
          'Slide sideways without turning: positive to the left, negative to the right.',
          params: [SkillParam('distance_m', ParamType.number, 'Sideways distance; positive is left.',
              min: -limits.maxDistance, max: limits.maxDistance, unit: 'm'), speed]),
      if (canTurnInPlace) Skill('rotate',
          'Turn in place: positive is counter-clockwise (left), negative is clockwise (right).',
          params: [SkillParam('angle_deg', ParamType.number, 'Angle to turn; positive turns left.',
              min: -limits.maxAngleDeg, max: limits.maxAngleDeg, unit: 'degrees'), speed]),
      if (canNavigate) const Skill('navigate_to',
          'Plan a path and drive to a position on the map, avoiding obstacles. Waits until arrival.',
          params: [
            SkillParam('x', ParamType.number, 'Map x coordinate.', unit: 'm'),
            SkillParam('y', ParamType.number, 'Map y coordinate.', unit: 'm'),
            SkillParam('yaw_deg', ParamType.number, 'Final heading in the map frame; 0 faces +x.',
                required: false, min: -180, max: 180, unit: 'degrees'),
          ]),
      if (canNavigate && places.isNotEmpty) Skill('go_to_place',
          'Navigate to a place the person saved on the map, by its name. Prefer this over coordinates '
          'whenever the person names a place. Waits until arrival.',
          params: [SkillParam('name', ParamType.string, 'The saved place to go to.',
              values: [for (final p in places) p.name])]),
      if (canNavigate) const Skill('cancel_navigation', 'Cancel the current navigation goal.'),
      if (routines.isNotEmpty) Skill('run_routine',
          'Run a routine the person saved (a fixed sequence of actions) by its name. Prefer this whenever the '
          'person names a routine. Waits until all its steps are done.',
          params: [SkillParam('name', ParamType.string, 'The saved routine to run.', values: routines)]),
      // Looking after the robot (nothing here moves it).
      if (abilities != null) const Skill('check_robot',
          'Check the robot\'s health: battery level, and recent warnings or errors from its programs. Use it '
          'for "how much battery is left", "is anything wrong", "any errors". Not for what it is doing now '
          '(that is get_status).'),
      if (abilities != null && abilities.localize) const Skill('find_position',
          'Work out where the robot is on the map by matching its laser scan to the map, and set it. The robot '
          'does not move. Use it when the robot seems lost, after it was carried, or when asked to relocalize.'),
      if (abilities != null && abilities.savePlace) const Skill('save_place',
          'Save the spot where the robot is now as a named place on the map, so it can go back there later.',
          params: [SkillParam('name', ParamType.string, 'Name for the place, as the person said it.')]),
      if (abilities != null && abilities.saveMap) const Skill('save_map',
          'Save the map the robot is making (on the robot and on the phone).',
          params: [SkillParam('name', ParamType.string, 'File name for the map; leave out for a dated name.',
              required: false)]),
      // The arm only goes to postures the person saved (or "home"): never to joint values a model makes up.
      if (armPoses.isNotEmpty) Skill('arm_to_pose',
          'Move the robot arm to a posture the person saved, by its name ("home" is its resting posture). '
          'Waits until the arm is there.',
          params: [SkillParam('name', ParamType.string, 'The saved arm posture.', values: armPoses)]),
      if (hasGripper) const Skill('gripper', 'Open or close the gripper at the end of the arm.',
          params: [SkillParam('action', ParamType.string, 'What to do with the gripper.', values: ['open', 'close'])]),
      // What the person tells the robot about itself or them: kept on the phone, never moves anything.
      if (canRemember) Skill('update_profile',
          'Remember a fact the person states about this robot or themselves: its name, what it is for, how it '
          'should talk, what kind of robot it is, or what to call the person. Only when they say it.',
          params: [
            SkillParam('field', ParamType.string, 'Which fact.', values: RobotPersona.fields.keys.toList()),
            SkillParam('value', ParamType.string, 'The value, in the person\'s words.'),
          ]),
      if (canRemember) const Skill('remember',
          'Keep a note the person asks this robot to keep in mind (a place to avoid, a habit, a preference).',
          params: [SkillParam('note', ParamType.string, 'The note, short, in the person\'s words.')]),
      if (canRemember) const Skill('learn_phrase',
          'Remember what the person means by a word or phrase of their own ("there" means the kitchen, '
          '"gently" means slowly). Only when they explain it.',
          params: [
            SkillParam('phrase', ParamType.string, 'Their word or phrase, exactly as they say it.'),
            SkillParam('meaning', ParamType.string, 'What it means, in plain words.'),
          ]),
      if (canRemember) const Skill('define_tool',
          'Make a reusable tool for this person and robot out of this robot\'s own skills, when they ask for one or '
          'keep asking for the same sequence. It is kept on the phone and offered to you later under its name. '
          'Steps run with the same checks as any call. Steps are fixed: never for a request that depends on a condition '
          '(do that one now, step by step), and never instead of doing what was asked.',
          params: [
            SkillParam('name', ParamType.string, 'Short English name, e.g. night_patrol.'),
            SkillParam('description', ParamType.string, 'When to use it, in one sentence.'),
            SkillParam('steps', ParamType.string, 'JSON list of steps, e.g. [{"skill":"go_to_place","name":"dock"},'
                '{"skill":"rotate","angle_deg":"{angle}"}]; "{p}" is replaced by parameter p.'),
            SkillParam('parameters', ParamType.string, 'Optional JSON list of parameters, e.g. '
                '[{"name":"angle","type":"number","description":"Turn","min":-180,"max":180}].', required: false),
          ]),
      // Tools learned for this person and robot (habits, and ones the assistant defined).
      for (final t in learned) t.toSkill(),
      if (canSaveRoutines) const Skill('save_routine',
          'Save the actions carried out so far in this instruction (or, if none, in the previous one) as a '
          'routine with this name, so the person can run it again or schedule it. Replaces a routine with the '
          'same name.',
          params: [SkillParam('name', ParamType.string, 'Name for the routine, as the person said it.')]),
    ];
    return AgentManifest._(skills, profile, canNavigate, limits, places, routines, const [], abilities, armPoses,
        persona == null || persona.isEmpty ? null : persona, const {}, learned, aliases);
  }

  final List<Skill> skills;
  final RobotProfile? profile;
  final bool canNavigate;
  final AgentLimits limits;
  /// Saved places (only offered with navigation).
  final List<Place> places;
  /// Names of saved routines.
  final List<String> routines;
  /// Who the robot is to its person (name, role, manner, notes), if they said.
  final RobotPersona? persona;
  /// For a fleet: each robot's persona, by robot name.
  final Map<String, RobotPersona> fleetPersonas;
  /// Tools learned for this person and robot (also among [skills]).
  final List<LearnedTool> learned;
  /// The person's own words for things: phrase -> meaning.
  final Map<String, String> aliases;

  /// For a fleet: the names people gave the robots, to the robot each means ("Sunny" -> robot1).
  Map<String, String> get fleetAliases => {
    for (final e in fleetPersonas.entries) if (e.value.name != null) e.value.name!: e.key,
  };
  final List<String> fleetRobots;
  /// Names of the arm postures the assistant may move the arm to (empty: no arm skills).
  final List<String> armPoses;
  /// Health, position and map tools the robot supports (null: none offered).
  final RobotAbilities? abilities;

  Place? place(String name) => places.where((p) => PlaceBook.normalize(p.name) == PlaceBook.normalize(name)).firstOrNull;

  Skill? skill(String name) => skills.where((s) => s.name == name).firstOrNull;

  /// The same tool list without [names] (what a small model is not asked to choose); without the person's
  /// own words too unless [aliases].
  AgentManifest without(Set<String> names, {bool aliases = true}) => AgentManifest._(
      [for (final s in skills) if (!names.contains(s.name)) s], profile, canNavigate, limits, places, routines,
      fleetRobots, abilities, armPoses, persona, fleetPersonas,
      [for (final t in learned) if (!names.contains(t.name)) t], aliases ? this.aliases : const {});

  /// Tool definitions for a model.
  List<Map<String, Object?>> toTools() => [for (final s in skills) s.toToolJson()];

  /// A few lines about the robot for the model's instructions.
  /// [brief]: without the robot's recent events, so the text stays the same between requests.
  String describe({bool brief = false}) {
    if (fleetRobots.isNotEmpty) {
      return 'This is a fleet of ${fleetRobots.join(', ')}. '
          'Every tool call must name its robot. Calls for different robots can run together; '
          'calls for one robot run in order. Use each robot\'s own saved places.'
          '${routines.isEmpty ? '' : ' Saved fleet routines: ${routines.join(', ')}.'}'
          '${fleetPersonas.isEmpty ? '' : ' ${[for (final e in fleetPersonas.entries) '${e.key}: ${e.value.describe(withRecent: !brief)}'].join(' ')}'
              ' When the person uses a robot\'s given name, use that robot.'}';
    }
    final p = profile;
    final base = switch (p?.drive) {
      DriveType.differential => 'a differential-drive base (drives forward/back and turns in place)',
      DriveType.holonomic => 'a holonomic base (moves in any direction and turns in place)',
      DriveType.ackermann => 'a car-like base (steers, cannot turn in place)',
      DriveType.aerial => 'a drone (not controllable by the assistant)',
      DriveType.none => 'no mobile base',
      null => 'an unknown base (not controllable until set up)',
    };
    return [
      if (persona != null) persona!.describe(withRecent: !brief),
      if (aliases.isNotEmpty)
        'The person\'s own words: ${[for (final e in aliases.entries) '"${e.key}" means ${e.value}'].join('; ')}.',
      'The robot has $base.',
      if (p != null && p.hasBase) 'Top speed is ${p.maxLinear} m/s; the assistant uses at most '
          '${(limits.speedScales.values.fold<double>(0, (a, b) => a > b ? a : b) * 100).round()}% of it.',
      canNavigate ? 'It has a map and can navigate to map coordinates.' : 'It cannot navigate on a map.',
      if (p != null && p.cameraSource == CameraSource.rosImage && p.cameraTopic.isNotEmpty)
        'It has a camera (${p.cameraTopic}); use look to see through it.',
      if (canNavigate && places.isNotEmpty)
        'Saved places on the map: ${[for (final p in places) p.name].join(', ')}.',
      if (routines.isNotEmpty) 'Saved routines: ${routines.join(', ')}.',
      if (armPoses.isNotEmpty) 'It has an arm that can go to these saved postures: ${armPoses.join(', ')}.',
      if (skill('gripper') != null) 'The arm has a gripper.',
      if (abilities?.battery != null) 'It reports its battery.',
      if (abilities?.saveMap == true) 'It is making a map right now.',
      'Single moves are limited to ${limits.maxDistance} m and ${limits.maxAngleDeg.round()} degrees.',
    ].join(' ');
  }
}
