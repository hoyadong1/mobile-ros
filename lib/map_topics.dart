import 'app_language.dart';
import 'dart:convert';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'topic_discovery.dart';

/// Topics and names the map screen can be pointed at by hand when automatic discovery picks wrong
/// (non-standard names such as /wheel_state for odometry).
enum MapSlot {
  map('Map', 'nav_msgs/OccupancyGrid', 'Occupancy grid to draw'),
  odom('Odometry', 'nav_msgs/Odometry', 'Robot motion; also names the base frame'),
  tf('TF', 'tf2_msgs/TFMessage', 'Transforms (map → odom → base)'),
  tfStatic('Static TF', 'tf2_msgs/TFMessage', 'Fixed transforms (sensor mounts)'),
  scan('LiDAR', 'sensor_msgs/LaserScan', 'Laser scan overlay'),
  plan('Planned path', 'nav_msgs/Path', 'Global plan overlay'),
  navAction('Nav2 action', '', 'NavigateToPose action server (ROS 2). Set to use goals with progress'),
  goal('Goal topic', 'geometry_msgs/PoseStamped', 'Used when there is no action server (ROS 2)'),
  initialPose('Initial pose', 'geometry_msgs/PoseWithCovarianceStamped', 'Set pose publishes here');

  const MapSlot(this.label, this.type, this.help);
  final String label;
  final String type; // empty: not a topic (action name)
  final String help;
}

/// Per-robot manual overrides; a slot that is absent uses automatic discovery.
class MapTopicStore {
  static String _key(String ip, String port) => 'map_topics:$ip:$port';

  static ({String ip, String port}) _split(String address) {
    final i = address.indexOf(':');
    return i < 0 ? (ip: address, port: '') : (ip: address.substring(0, i), port: address.substring(i + 1));
  }

  /// By a saved robot's address key (see RobotSession.storeAddress).
  static Future<Map<MapSlot, String>> loadAt(String address) => load(_split(address).ip, _split(address).port);
  static Future<void> saveAt(String address, Map<MapSlot, String> overrides) =>
      save(_split(address).ip, _split(address).port, overrides);

  static Future<Map<MapSlot, String>> load(String ip, String port) async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(_key(ip, port));
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final slot in MapSlot.values)
          if (decoded[slot.name] is String && (decoded[slot.name] as String).startsWith('/'))
            slot: decoded[slot.name] as String,
      };
    } catch (_) {
      return {}; // preferences unavailable (tests, corrupted data): automatic discovery only
    }
  }

  static Future<void> save(String ip, String port, Map<MapSlot, String> overrides) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(ip, port), jsonEncode({for (final e in overrides.entries) e.key.name: e.value}));
  }
}

/// Bottom sheet listing every slot: the value in use, whether it is automatic, candidates of the right
/// type from the robot, and a free-text field. Returns the new overrides, or null if cancelled.
Future<Map<MapSlot, String>?> showMapTopicSheet(BuildContext context, {
  required Map<MapSlot, String> overrides,
  required Map<MapSlot, String?> automatic,
  required Map<String, dynamic>? topics,
  required List<String> actions,
}) => showModalBottomSheet<Map<MapSlot, String>>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _MapTopicSheet(overrides: overrides, automatic: automatic, topics: topics, actions: actions),
);

class _MapTopicSheet extends StatefulWidget {
  const _MapTopicSheet({required this.overrides, required this.automatic, required this.topics, required this.actions});
  final Map<MapSlot, String> overrides;
  final Map<MapSlot, String?> automatic;
  final Map<String, dynamic>? topics;
  final List<String> actions;

  @override
  State<_MapTopicSheet> createState() => _MapTopicSheetState();
}

class _MapTopicSheetState extends State<_MapTopicSheet> {
  late final controllers = {
    for (final slot in MapSlot.values) slot: TextEditingController(text: widget.overrides[slot] ?? ''),
  };
  final _form = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> _candidates(MapSlot slot) => slot == MapSlot.navAction
      ? widget.actions.where((a) => a.endsWith('navigate_to_pose')).toList()
      : topicsOfType(widget.topics, slot.type);

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SafeArea(child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: Form(key: _form, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), children: [
            Text(context.strings.mapTopics, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            Text(context.strings.mapTopicsHelp,
              style: TextStyle(color: Colors.blueGrey.shade600, fontSize: 12)),
            const SizedBox(height: 16),
            for (final slot in MapSlot.values) _row(slot),
          ])),
          // Actions stay pinned below the scrolling list.
          Padding(padding: const EdgeInsets.fromLTRB(20, 4, 20, 12), child: Row(children: [
            TextButton(key: const Key('map-topics-reset'),
              onPressed: () => setState(() { for (final c in controllers.values) { c.clear(); } }),
              child: Text(context.strings.allAutomatic)),
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.strings.cancel)),
            const SizedBox(width: 8),
            FilledButton(key: const Key('map-topics-save'), onPressed: () {
              if (!_form.currentState!.validate()) return;
              Navigator.pop(context, {
                for (final e in controllers.entries)
                  if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
              });
            }, child: Text(context.strings.apply)),
          ])),
        ])),
      )),
    );
  }

  Widget _row(MapSlot slot) {
    final candidates = _candidates(slot);
    final auto = widget.automatic[slot];
    return Padding(padding: const EdgeInsets.only(bottom: 14), child: TextFormField(
      key: Key('map-topic-${slot.name}'),
      controller: controllers[slot],
      autocorrect: false,
      decoration: InputDecoration(
        labelText: slotLabel(context, slot),
        hintText: auto == null ? context.strings.autoNotFound : context.strings.autoValue(auto),
        helperText: slotHelp(context, slot),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        suffixIcon: candidates.isEmpty ? null : PopupMenuButton<String>(
          key: Key('map-topic-pick-${slot.name}'),
          tooltip: context.strings.chooseFromRobot,
          icon: const Icon(Icons.arrow_drop_down),
          itemBuilder: (_) => [for (final c in candidates) PopupMenuItem(value: c, child: Text(c))],
          onSelected: (value) => setState(() => controllers[slot]!.text = value),
        ),
      ),
      validator: (value) {
        final v = value?.trim() ?? '';
        if (v.isEmpty) return null;
        if (!v.startsWith('/') || v.contains(RegExp(r'\s'))) return context.strings.startWithSlash;
        return null;
      },
    ));
  }
}

/// A map slot's name and help in the app's language.
String slotLabel(BuildContext context, MapSlot slot) {
  final s = context.strings;
  return switch (slot) {
    MapSlot.map => s.slotMap, MapSlot.odom => s.slotOdom, MapSlot.tf => s.slotTf, MapSlot.tfStatic => s.slotTfStatic,
    MapSlot.scan => s.slotScan, MapSlot.plan => s.plannedPath, MapSlot.navAction => s.slotNavAction,
    MapSlot.goal => s.slotGoal, MapSlot.initialPose => s.slotInitialPose,
  };
}

String slotHelp(BuildContext context, MapSlot slot) {
  final s = context.strings;
  return switch (slot) {
    MapSlot.map => s.slotMapHelp, MapSlot.odom => s.slotOdomHelp, MapSlot.tf => s.slotTfHelp,
    MapSlot.tfStatic => s.slotTfStaticHelp, MapSlot.scan => s.slotScanHelp, MapSlot.plan => s.slotPlanHelp,
    MapSlot.navAction => s.slotNavActionHelp, MapSlot.goal => s.slotGoalHelp, MapSlot.initialPose => s.slotInitialPoseHelp,
  };
}
