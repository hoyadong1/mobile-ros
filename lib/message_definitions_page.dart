import 'app_language.dart';
import 'package:material_ui/material_ui.dart';

import 'dds/custom_interfaces.dart';
import 'dds/direct.dart';
import 'dds/ros_interfaces.dart';

/// Lets the user add the .msg / .srv / .action definitions of their robot's own packages, which the
/// direct ROS 2 connection needs to read and write those messages (rosbridge gets them from the robot).
class MessageDefinitionsPage extends StatefulWidget {
  const MessageDefinitionsPage({super.key, this.session, this.bundled});

  /// When connected directly: definitions apply at once and the robot's unknown types are listed.
  final DirectRosSession? session;

  /// The built-in definitions (loaded from assets when null).
  final RosInterfaces? bundled;

  @override
  State<MessageDefinitionsPage> createState() => _MessageDefinitionsPageState();
}

class _MessageDefinitionsPageState extends State<MessageDefinitionsPage> {
  Map<String, String> custom = {};
  RosInterfaces? known; // bundled + custom, for validation
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final saved = await loadCustomInterfaces();
    final base = widget.session?.interfaces ?? widget.bundled ?? await loadBundledInterfaces();
    saved.forEach(base.add);
    if (!mounted) return;
    setState(() {
      custom = saved;
      known = base;
      loading = false;
    });
  }

  Future<void> _save(String type, String text, {String? replacing}) async {
    setState(() {
      if (replacing != null && replacing != type) custom.remove(replacing);
      custom[type] = text;
    });
    known!.add(type, text);
    await saveCustomInterfaces(custom);
  }

  Future<void> _delete(String type) async {
    setState(() => custom.remove(type));
    await saveCustomInterfaces(custom);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(context.strings.removedTypeUsable(type)),
    ));
  }

  Future<void> _edit({String? type, String? text, String? suggested}) async {
    final result = await Navigator.push<(String, String)>(context, MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => DefinitionEditor(known: known!, type: type ?? suggested, text: text, existing: custom.keys.toSet()),
    ));
    if (result != null) await _save(result.$1, result.$2, replacing: type);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unknown = widget.session?.unknownInterfaces.where((t) => !custom.containsKey(t)).toList() ?? const <String>[];
    return Scaffold(
      appBar: AppBar(title: Text(context.strings.messageDefinitions)),
      floatingActionButton: loading ? null : FloatingActionButton.extended(
        key: const Key('add-definition'), onPressed: () => _edit(),
        icon: const Icon(Icons.add), label: Text(context.strings.addDefinition)),
      body: loading ? const Center(child: CircularProgressIndicator()) : ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          Text(context.strings.definitionsIntro,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          if (unknown.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text(context.strings.neededByRobot, style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2)),
            const SizedBox(height: 4),
            for (final t in unknown) ListTile(
              key: Key('unknown-$t'), contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.help_outline, color: Color(0xFFB26A00)),
              title: Text(t, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text(context.strings.cannotReadYet),
              trailing: TextButton(onPressed: () => _edit(suggested: t), child: Text(context.strings.add)),
            ),
          ],
          const SizedBox(height: 20),
          Text(context.strings.yourDefinitions, style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2)),
          const SizedBox(height: 4),
          if (custom.isEmpty)
            Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text(context.strings.noneYet))
          else
            for (final e in (custom.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
              _definitionTile(e.key, e.value),
        ],
      ),
    );
  }

  Widget _definitionTile(String type, String text) {
    final check = checkDefinition(type, text, known!);
    final status = check.error ?? (check.missing.isEmpty
        ? context.strings.fieldsCount(check.fields)
        : context.strings.alsoNeeds(check.missing.join(', ')));
    return Card(child: ListTile(
      key: Key('definition-$type'),
      leading: Icon(check.ok ? Icons.check_circle_outline : Icons.warning_amber_rounded,
        color: check.ok ? const Color(0xFF277A59) : const Color(0xFFB26A00)),
      title: Text(type, style: const TextStyle(fontFamily: 'monospace')),
      subtitle: Text(status),
      onTap: () => _edit(type: type, text: text),
      trailing: IconButton(tooltip: context.strings.delete, icon: const Icon(Icons.delete_outline), onPressed: () => _delete(type)),
    ));
  }
}

class DefinitionEditor extends StatefulWidget {
  const DefinitionEditor({super.key, required this.known, this.type, this.text, this.existing = const {}});
  final RosInterfaces known;
  final String? type, text;
  final Set<String> existing;

  @override
  State<DefinitionEditor> createState() => _DefinitionEditorState();
}

class _DefinitionEditorState extends State<DefinitionEditor> {
  late final _name = TextEditingController(text: widget.type ?? '');
  late final _body = TextEditingController(text: widget.text ?? '');

  @override
  void dispose() {
    _name.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = interfaceName(_name.text);
    final check = type == null
        ? DefinitionCheck(error: context.strings.nameTypeLike)
        : _body.text.trim().isEmpty
            ? DefinitionCheck(error: context.strings.pasteDefinition)
            : checkDefinition(type, _body.text, widget.known);
    final replacesBuiltIn = type != null && !widget.existing.contains(type) && widget.known.has(_probe(type));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.type == null ? context.strings.addDefinition : context.strings.editDefinition),
        actions: [
          TextButton(key: const Key('save-definition'),
            onPressed: check.error == null ? () => Navigator.pop(context, (type!, _body.text.trim())) : null,
            child: Text(context.strings.save)),
        ],
      ),
      body: SafeArea(child: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          key: const Key('definition-name'), controller: _name, autocorrect: false, enableSuggestions: false,
          decoration: InputDecoration(labelText: context.strings.typeLabel, hintText: 'my_robot_msgs/msg/Status',
            helperText: context.strings.typeFormatHelp, border: OutlineInputBorder()),
          style: const TextStyle(fontFamily: 'monospace'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('definition-text'), controller: _body, minLines: 8, maxLines: null,
          autocorrect: false, enableSuggestions: false, keyboardType: TextInputType.multiline,
          decoration: InputDecoration(labelText: context.strings.definition, alignLabelWithHint: true,
            hintText: 'std_msgs/Header header\nuint8 MODE_AUTO=1\nuint8 mode\nfloat32[] values',
            border: OutlineInputBorder()),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        if (check.error != null)
          _note(Icons.error_outline, theme.colorScheme.error, check.error!)
        else if (check.missing.isNotEmpty)
          _note(Icons.warning_amber_rounded, const Color(0xFFB26A00),
            context.strings.usesUnknownTypes(check.missing.join(', ')))
        else
          _note(Icons.check_circle_outline, const Color(0xFF277A59), '${check.fields} field${check.fields == 1 ? '' : 's'}, ready to use'),
        if (replacesBuiltIn)
          _note(Icons.info_outline, theme.colorScheme.primary, context.strings.replacesBuiltIn(type)),
      ])),
    );
  }

  /// A concrete type to test whether [type] is already known (services and actions by one of their parts).
  static String _probe(String type) =>
      type.contains('/srv/') ? '${type}_Request' : type.contains('/action/') ? '${type}_Goal' : type;

  Widget _note(IconData icon, Color color, String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, size: 18, color: color),
      const SizedBox(width: 8),
      Expanded(child: Text(text, style: TextStyle(color: color))),
    ]),
  );
}
