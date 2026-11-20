import 'app_language.dart';
import 'dart:async';
import 'app_theme.dart';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'message_codec.dart' show validateMessageFields;
import 'message_schema.dart';
import 'ros_connection.dart';
import 'widgets/status_panel.dart';

typedef PublishConnectionFactory =
    RosConnection Function(String host, String port);

class PublishPage extends StatefulWidget {
  const PublishPage({
    super.key,
    required this.ip,
    required this.port,
    this.connectionFactory,
  });

  final String ip;
  final String port;
  final PublishConnectionFactory? connectionFactory;

  @override
  State<PublishPage> createState() => _PublishPageState();
}

class _PublishPageState extends State<PublishPage> {
  final _formKey = GlobalKey<FormState>();
  final _topicController = TextEditingController();
  final _topicFocus = FocusNode();
  final _jsonController = TextEditingController();
  final Map<String, TextEditingController> _fieldControllers = {};
  final List<({String topic, String type, String preview})> _recent = [];

  RosConnection? _connection;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  final Map<String, dynamic> _localDefinitions = {};
  final Set<String> _builtInTypes = {};
  final Map<String, String> _topicTypes = {};
  List<String> _topics = [];
  List<String> _types = [];
  String? _selectedType;
  MessageSchema? _schema;
  String? _status;
  bool _statusIsError = true;
  bool _connected = false;
  bool _loadingTopics = false;
  bool _loadingSchema = false;
  bool _jsonMode = false;
  bool _repeating = false;
  int _rateHz = 5;
  int _sentCount = 0;
  int _schemaRequest = 0;
  Timer? _publishTimer;
  String? _advertisedTopic;
  String? _advertisedType;

  @override
  void initState() {
    super.initState();
    _loadLocalDefinitions();
    _connect();
  }

  Future<void> _loadLocalDefinitions() async {
    try {
      final bundled = Map<String, dynamic>.from(
        jsonDecode(await rootBundle.loadString('assets/message_types.json'))
            as Map,
      );
      var saved = <String, dynamic>{};
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/message_types.json');
      if (await file.exists()) {
        try {
          saved = Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          );
          for (final value in saved.values) {
            if (value is! Map || value['fields'] is! Map) {
              throw const FormatException('Invalid saved message definitions');
            }
            validateMessageFields(
              Map<String, dynamic>.from(value['fields'] as Map),
            );
          }
        } catch (_) {
          saved = {};
          if (mounted) _showStatus(context.strings.savedTypesInvalid, error: true);
        }
      }
      if (!mounted) return;
      setState(() {
        _localDefinitions
          ..clear()
          ..addAll(bundled)
          ..addAll(saved);
        _builtInTypes
          ..clear()
          ..addAll(bundled.keys);
        _refreshTypeChoices();
      });
    } catch (error) {
      _showStatus(context.strings.offlineTypesError('$error'), error: true);
    }
  }

  Future<void> _connect() async {
    try {
      final client =
          widget.connectionFactory?.call(widget.ip, widget.port) ??
          RosConnection(widget.ip, widget.port);
      _connection = client;
      _subscription = client.messages.listen(
        (message) {
          if (!mounted) return;
          if (message['level'] == 'error') {
            _showStatus(
              context.strings.robotRejected('${message['msg'] ?? message}'),
              error: true,
            );
          }
        },
        onError: (Object error) {
          if (mounted) _showStatus(context.strings.connectionError('$error'), error: true);
        },
        onDone: () {
          if (!mounted) return;
          setState(() => _connected = false);
          _showStatus(
            client.lastError ?? context.strings.robotConnectionClosed,
            error: true,
          );
        },
      );
      await client.ready;
      if (!mounted) return;
      setState(() => _connected = true);
      await _discoverTopics();
    } catch (error) {
      if (mounted) _showStatus(context.strings.cannotConnectRobot('$error'), error: true);
    }
  }

  Future<void> _discoverTopics() async {
    final client = _connection;
    if (client == null || !_connected) return;
    setState(() => _loadingTopics = true);
    try {
      final response = await client.call('/rosapi/topics');
      final names =
          (response['topics'] as List?)?.map((value) => '$value').toList() ??
          <String>[];
      final types =
          (response['types'] as List?)?.map((value) => '$value').toList() ??
          <String>[];
      final topicTypes = <String, String>{};
      for (var i = 0; i < names.length && i < types.length; i++) {
        topicTypes[names[i]] = types[i];
      }

      final discoveredTypes = <String>{...types};
      try {
        // ROS 2 rosapi lists every installed interface (msg, srv, action); keep the messages.
        final response = await client.call('/rosapi/interfaces');
        final installed = response['interfaces'];
        if (installed is List) {
          discoveredTypes.addAll(installed.map((value) => '$value').where((t) => t.contains('/msg/')));
        }
      } catch (_) {
        // ROS 1 rosapi has no interfaces service; the types of existing topics still work.
      }
      if (!mounted) return;
      setState(() {
        _topics = names.toSet().toList()..sort();
        _topicTypes
          ..clear()
          ..addAll(topicTypes);
        _types = discoveredTypes.toList()..sort();
        _refreshTypeChoices();
        _loadingTopics = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingTopics = false);
      _showStatus(
        context.strings.rosTopicsReadError('$error'),
        error: true,
      );
    }
  }

  void _refreshTypeChoices() {
    _types = {
      ..._types,
      ..._topicTypes.values,
      ..._localDefinitions.keys,
    }.toList()..sort();
  }

  Future<void> _selectTopic(String topic) async {
    _topicController.text = topic;
    final type = _topicTypes[topic];
    if (type == null) return;
    await _selectType(type);
  }

  Future<void> _selectType(String? type) async {
    if (type == null || type.isEmpty) return;
    _stopRepeating(publishStop: true);
    _releasePublisher();
    final request = ++_schemaRequest;
    _disposeFieldControllers();
    setState(() {
      _selectedType = type;
      _schema = null;
      _loadingSchema = true;
      _jsonMode = false;
      _status = null;
    });

    MessageSchema? loaded;
    Object? remoteError;
    final client = _connection;
    if (client != null && _connected) {
      try {
        final response = await client.call('/rosapi/message_details', {
          'type': type,
        });
        loaded = MessageSchema.fromRosapi(response);
      } catch (error) {
        remoteError = error;
      }
    }
    if (loaded == null) {
      final localType = _localDefinitions.keys.cast<String?>().firstWhere(
        (name) => name != null && normalizeType(name) == normalizeType(type),
        orElse: () => null,
      );
      final definition = localType == null
          ? null
          : _localDefinitions[localType];
      if (definition is Map && definition['fields'] is Map) {
        try {
          loaded = MessageSchema.fromLegacy(localType!, _localDefinitions);
        } catch (error) {
          remoteError ??= error;
        }
      }
    }
    if (!mounted || request != _schemaRequest) return;
    if (loaded == null) {
      setState(() => _loadingSchema = false);
      _showStatus(
        context.strings.schemaLoadError(type, remoteError == null ? '' : ': $remoteError'),
        error: true,
      );
      return;
    }
    final resolved = loaded;
    setState(() {
      _schema = resolved;
      _loadingSchema = false;
      _seedForm(resolved, resolved.defaults());
      _jsonController.text = _pretty(resolved.defaults());
    });
  }

  void _seedForm(MessageSchema schema, Map<String, dynamic> message) {
    _disposeFieldControllers();
    void visit(String type, Map<String, dynamic> values, String prefix) {
      final definition = schema.def(type);
      if (definition == null) return;
      for (final field in definition.fields) {
        final path = _path(prefix, field.name);
        final value = values[field.name] ?? schema.defaultField(field);
        if (!field.isArray && schema.isMessage(field.type) && value is Map) {
          visit(field.type, Map<String, dynamic>.from(value), path);
        } else {
          _fieldControllers[path] = TextEditingController(
            text: _fieldText(field, value),
          );
        }
      }
    }

    visit(schema.root, message, '');
  }

  String _fieldText(FieldDef field, Object? value) =>
      field.isArray && value is! String
      ? const JsonEncoder.withIndent('  ').convert(value)
      : formatPrimitive(value);

  String _path(String prefix, String key) =>
      prefix.isEmpty ? key : '$prefix/$key';

  dynamic _rawField(FieldDef field, String path) {
    final text = _fieldControllers[path]?.text ?? '';
    if (!field.isArray) return text;
    if ((field.type == 'uint8' ||
            field.type == 'byte' ||
            field.type == 'octet') &&
        text.isNotEmpty &&
        !text.trimLeft().startsWith('[')) {
      return text;
    }
    if (text.trim().isEmpty) return <dynamic>[];
    return jsonDecode(text);
  }

  Map<String, dynamic> _rawForm([String type = '', String prefix = '']) {
    final schema = _schema!;
    final currentType = type.isEmpty ? schema.root : type;
    final definition = schema.def(currentType)!;
    return {
      for (final field in definition.fields)
        field.name: !field.isArray && schema.isMessage(field.type)
            ? _rawForm(field.type, _path(prefix, field.name))
            : _rawField(field, _path(prefix, field.name)),
    };
  }

  Map<String, dynamic> _messageFromForm() => _schema!.coerce(_rawForm());

  /// Error text for people: no "FormatException:" / "Bad state:" prefixes.
  static String _plain(Object error) => error is FormatException ? error.message
      : '$error'.replaceFirst(RegExp(r'^(Bad state|StateError|Exception): '), '');

  String? _validateField(FieldDef field, String path, String? value) {
    try {
      final schema = _schema!;
      dynamic raw = value ?? '';
      if (field.isArray) {
        if ((field.type == 'uint8' ||
                field.type == 'byte' ||
                field.type == 'octet') &&
            (value ?? '').isNotEmpty &&
            !(value ?? '').trimLeft().startsWith('[')) {
          raw = value;
        } else {
          raw = (value ?? '').trim().isEmpty ? <dynamic>[] : jsonDecode(value!);
        }
      }
      schema.coerceField(field, raw, path);
      return null;
    } catch (error) {
      // The field already shows which field this is, so drop the "linear/x: " prefix.
      return error is FormatException
          ? error.message.toString().replaceFirst('$path: ', '')
          : context.strings.enterValidValue;
    }
  }

  Widget _buildFields(
    String type, {
    String prefix = '',
    int depth = 0,
    Set<String> parents = const {},
  }) {
    final schema = _schema!;
    final definition = schema.def(type);
    if (definition == null || parents.contains(type)) {
      return Text(
        context.strings.recursiveField,
      );
    }
    final nextParents = {...parents, type};
    final compact = definition.fields.isNotEmpty && definition.fields.length <= 4 &&
        definition.fields.every((f) => !f.isArray && (isIntType(f.type) || isFloatType(f.type)));
    if (compact) {
      // x / y / z (/ w) side by side instead of one tall field per line.
      return Padding(padding: const EdgeInsets.only(top: 4), child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < definition.fields.length; i++) ...[
            if (i > 0) const SizedBox(width: 8),
            Expanded(child: _buildField(definition.fields[i], prefix, definition, compact: true)),
          ],
        ],
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final field in definition.fields)
          if (!field.isArray && schema.isMessage(field.type))
            Padding(
              padding: EdgeInsets.only(left: depth == 0 ? 0 : 12, bottom: 10),
              child: Card(
                margin: EdgeInsets.zero,
                child: ExpansionTile(
                  initiallyExpanded: depth == 0,
                  title: Text(
                    field.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    normalizeType(field.type),
                    overflow: TextOverflow.ellipsis,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                  children: [
                    _buildFields(
                      field.type,
                      prefix: _path(prefix, field.name),
                      depth: depth + 1,
                      parents: nextParents,
                    ),
                  ],
                ),
              ),
            )
          else
            _buildField(field, prefix, definition),
      ],
    );
  }

  Widget _buildField(FieldDef field, String prefix, TypeDef parent, {bool compact = false}) {
    final path = _path(prefix, field.name);
    final controller = _fieldControllers[path]!;
    final boolType = isBoolType(field.type);
    final hint = field.isArray
        ? (field.arrayLen > 0 ? context.strings.exactlyItems(field.arrayLen) : context.strings.jsonArray)
        : null; // scalar types are in the label
    final label = compact ? field.name : '${field.name}  ·  ${field.type}';
    final constants = parent.constants.entries.where((entry) {
      final name = field.name.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
      final constant = entry.key.toUpperCase().replaceAll(
        RegExp('[^A-Z0-9]'),
        '',
      );
      return name.isNotEmpty && constant.contains(name);
    }).toList();

    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (boolType)
            DropdownButtonFormField<String>(
              key: ValueKey('field:$path:${_selectedType ?? ''}'),
              initialValue:
                  controller.text == 'true' || controller.text == 'false'
                  ? controller.text
                  : null,
              decoration: InputDecoration(labelText: label, helperText: hint),
              items: [
                DropdownMenuItem(value: 'true', child: Text(context.strings.trueLabel)),
                DropdownMenuItem(value: 'false', child: Text(context.strings.falseLabel)),
              ],
              validator: (value) =>
                  value == null ? context.strings.chooseTrueFalse : null,
              onChanged: _repeating
                  ? null
                  : (value) {
                      if (value != null) controller.text = value;
                    },
            )
          else
            TextFormField(
              key: ValueKey('field:$path:${_selectedType ?? ''}'),
              controller: controller,
              enabled: !_repeating,
              minLines: field.isArray ? 2 : 1,
              maxLines: field.isArray ? 5 : 1,
              keyboardType: field.isArray || isStringType(field.type)
                  ? (field.isArray
                        ? TextInputType.multiline
                        : TextInputType.text)
                  : TextInputType.numberWithOptions(
                      decimal: isFloatType(field.type),
                      signed: !field.type.startsWith('u'),
                    ),
              decoration: InputDecoration(
                labelText: label,
                helperText: hint,
                isDense: compact,
                errorMaxLines: 2,
                alignLabelWithHint: field.isArray,
              ),
              // Re-check while typing, so a corrected value clears its error at once.
              autovalidateMode: AutovalidateMode.onUserInteraction,
              validator: (value) => _validateField(field, path, value),
            ),
          if (constants.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final constant in constants)
                    ActionChip(
                      label: Text(constant.key),
                      onPressed: _repeating
                          ? null
                          : () => controller.text = constant.value,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleJsonMode() async {
    final schema = _schema;
    if (schema == null || _repeating) return;
    if (!_jsonMode) {
      try {
        _jsonController.text = _pretty(_messageFromForm());
      } catch (_) {
        // Keep the last valid JSON visible; the form keeps its inline validation errors.
      }
      setState(() => _jsonMode = true);
      return;
    }
    try {
      final parsed = jsonDecode(_jsonController.text);
      final typed = schema.coerce(parsed);
      setState(() {
        _seedForm(schema, typed);
        _jsonMode = false;
      });
    } catch (error) {
      _showStatus(
        context.strings.fixJsonFirst('$error'),
        error: true,
      );
    }
  }

  String _pretty(Object? value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  Map<String, dynamic> _currentMessage() {
    if (_jsonMode) {
      final decoded = jsonDecode(_jsonController.text);
      return _schema!.coerce(decoded);
    }
    if (!_formKey.currentState!.validate()) {
      throw FormatException(context.strings.checkHighlighted);
    }
    return _messageFromForm();
  }

  void _publishOnce() {
    try {
      final message = _currentMessage();
      _publish(message);
      _record(message);
      _showStatus(
        context.strings.publishSent(_topicController.text.trim()),
        error: false,
      );
    } catch (error) {
      _showStatus(context.strings.cannotPublish(_plain(error)), error: true);
    }
  }

  void _startRepeating() {
    try {
      final message = _currentMessage();
      _publish(message);
      _record(message);
      setState(() {
        _repeating = true;
        _sentCount = 1;
      });
      _showStatus(
        context.strings.publishingAt(_rateHz),
        error: false,
      );
      _publishTimer = Timer.periodic(
        Duration(milliseconds: (1000 / _rateHz).round()),
        (_) {
          if (!mounted || !_repeating) return;
          try {
            _publish(message);
            setState(() => _sentCount++);
          } catch (error) {
            _stopRepeating(publishStop: true);
            _showStatus(context.strings.repeatStopped(_plain(error)), error: true);
          }
        },
      );
    } catch (error) {
      _showStatus(context.strings.repeatStartFailed(_plain(error)), error: true);
    }
  }

  void _stopRepeating({bool publishStop = false, bool leaving = false}) {
    _publishTimer?.cancel();
    _publishTimer = null;
    if (publishStop &&
        _repeating &&
        _isTwist(_advertisedType) &&
        _schema != null) {
      try {
        _publish(_zeroMessage(_schema!, _schema!.root));
        if (!leaving) {
          _showStatus(
            context.strings.stoppedZero,
            error: false,
          );
        }
      } catch (_) {}
    }
    if (publishStop && _repeating) _releasePublisher(stopTwist: false);
    if (_repeating && mounted && !leaving) setState(() => _repeating = false);
    if (leaving) _repeating = false;
  }

  bool _isTwist(String? type) {
    final normalized = normalizeType(type ?? '');
    return normalized.endsWith('/Twist') ||
        normalized.endsWith('/TwistStamped');
  }

  Map<String, dynamic> _zeroMessage(MessageSchema schema, String type) {
    final definition = schema.def(type)!;
    return {
      for (final field in definition.fields)
        field.name: field.isArray
            ? <dynamic>[]
            : schema.isMessage(field.type)
            ? _zeroMessage(schema, field.type)
            : isBoolType(field.type)
            ? false
            : isStringType(field.type)
            ? ''
            : (isIntType(field.type) || isFloatType(field.type))
            ? 0
            : schema.defaultField(field),
    };
  }

  void _publish(Map<String, dynamic> message) {
    final connection = _connection;
    final topic = _topicController.text.trim();
    final type = _selectedType;
    if (connection == null || !_connected || type == null) {
      throw StateError(context.strings.connectionUnavailable);
    }
    if (topic.isEmpty || RegExp(r'\s').hasMatch(topic)) {
      throw FormatException(context.strings.enterValidTopic);
    }
    if (_advertisedTopic != topic || _advertisedType != type) {
      _releasePublisher();
      connection.send({
        'op': 'advertise',
        'topic': topic,
        'type': type,
        'queue_size': 1,
      });
      _advertisedTopic = topic;
      _advertisedType = type;
    }
    connection.send({'op': 'publish', 'topic': topic, 'msg': message});
  }

  void _releasePublisher({bool stopTwist = true}) {
    final connection = _connection;
    final topic = _advertisedTopic;
    if (connection != null && topic != null && !connection.isClosed) {
      if (stopTwist && _isTwist(_advertisedType) && _schema != null) {
        try {
          connection.send({
            'op': 'publish',
            'topic': topic,
            'msg': _zeroMessage(_schema!, _schema!.root),
          });
        } catch (_) {}
      }
      try {
        connection.send({'op': 'unadvertise', 'topic': topic});
      } catch (_) {}
    }
    _advertisedTopic = null;
    _advertisedType = null;
  }

  void _record(Map<String, dynamic> message, {bool updateStatus = true}) {
    final record = (
      topic: _topicController.text.trim(),
      type: _selectedType ?? '',
      preview: _pretty(message),
    );
    _recent.removeWhere((r) => r.topic == record.topic && r.type == record.type && r.preview == record.preview);
    _recent.insert(0, record);
    if (_recent.length > 5) _recent.removeLast();
    if (mounted) setState(() {});
    if (updateStatus) _sentCount++;
  }

  Future<void> _addCustomType() async {
    final typeController = TextEditingController();
    final fieldsController = TextEditingController(
      text: '{\n  "data": "string"\n}',
    );
    final result = await showDialog<(String, Map<String, dynamic>)>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.addCustomType),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: typeController,
                decoration: InputDecoration(
                  labelText: context.strings.typeName,
                  hintText: 'my_msgs/Status',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: fieldsController,
                minLines: 5,
                maxLines: 12,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  labelText: context.strings.fieldsAsJson,
                  alignLabelWithHint: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.cancel),
          ),
          FilledButton(
            onPressed: () {
              try {
                final name = typeController.text.trim();
                final fields = jsonDecode(fieldsController.text);
                if (name.isEmpty || fields is! Map<String, dynamic>) {
                  throw FormatException(
                    context.strings.enterTypeAndJson,
                  );
                }
                if (_localDefinitions.containsKey(name)) {
                  throw FormatException(
                    '$name is already available. Choose a different name.',
                  );
                }
                validateMessageFields(fields);
                Navigator.pop(context, (name, fields));
              } catch (error) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.strings.invalidCustomType('$error'))),
                );
              }
            },
            child: Text(context.strings.addType),
          ),
        ],
      ),
    );
    typeController.dispose();
    fieldsController.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _localDefinitions[result.$1] = {'fields': result.$2};
      _refreshTypeChoices();
    });
    try {
      await _saveCustomTypes();
      await _selectType(result.$1);
      if (mounted) _showStatus(context.strings.addedType(result.$1), error: false);
    } catch (error) {
      if (mounted) _showStatus(context.strings.customTypesSaveError('$error'), error: true);
    }
  }

  Future<void> _manageCustomTypes() async {
    final custom =
        _localDefinitions.keys
            .where((key) => !_builtInTypes.contains(key))
            .toList()
          ..sort();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.strings.customTypes),
        content: SizedBox(
          width: 480,
          child: custom.isEmpty
              ? Text(context.strings.noCustomTypes)
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: custom.length,
                  itemBuilder: (context, index) {
                    final type = custom[index];
                    return ListTile(
                      title: Text(type),
                      trailing: IconButton(
                        tooltip: context.strings.deleteNamed(type),
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          setState(() {
                            _localDefinitions.remove(type);
                            _refreshTypeChoices();
                          });
                          if (_selectedType == type) {
                            setState(() {
                              _selectedType = null;
                              _schema = null;
                            });
                            _disposeFieldControllers();
                          }
                          try {
                            await _saveCustomTypes();
                            if (!context.mounted) return;
                            Navigator.pop(context);
                            _showStatus(context.strings.removedTypeShort(type), error: false);
                          } catch (error) {
                            _showStatus(
                              context.strings.customTypesSaveError('$error'),
                              error: true,
                            );
                          }
                        },
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.strings.close),
          ),
        ],
      ),
    );
  }

  Future<void> _saveCustomTypes() async {
    final custom = Map<String, dynamic>.fromEntries(
      _localDefinitions.entries.where(
        (entry) => !_builtInTypes.contains(entry.key),
      ),
    );
    if (kIsWeb) return; // no app documents folder in a browser: custom types last for this session
    final dir = await getApplicationDocumentsDirectory();
    await File(
      '${dir.path}/message_types.json',
    ).writeAsString(jsonEncode(custom));
  }

  void _showStatus(String message, {required bool error}) {
    if (!mounted) return;
    setState(() {
      _status = message;
      _statusIsError = error;
    });
  }

  void _disposeFieldControllers() {
    for (final controller in _fieldControllers.values) {
      controller.dispose();
    }
    _fieldControllers.clear();
  }

  @override
  void dispose() {
    _stopRepeating(publishStop: true, leaving: true);
    _releasePublisher();
    _subscription?.cancel();
    _connection?.close();
    _disposeFieldControllers();
    _topicController.dispose();
    _topicFocus.dispose();
    _jsonController.dispose();
    super.dispose();
  }

  Widget _actionBar() => Material(
    elevation: 8,
    color: context.card,
    child: SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(children: [
        Expanded(child: FilledButton.icon(
          key: const Key('publish-once'),
          onPressed: _connected && !_repeating && _schema != null ? _publishOnce : null,
          icon: const Icon(Icons.send_outlined),
          label: Text(context.strings.publish),
        )),
        const SizedBox(width: 10),
        Expanded(child: _repeating
            ? FilledButton.tonalIcon(
                key: const Key('publish-stop'),
                onPressed: () => _stopRepeating(publishStop: true),
                icon: const Icon(Icons.stop_circle_outlined),
                label: Text(context.strings.stopCount(_sentCount), maxLines: 1),
              )
            : OutlinedButton.icon(
                key: const Key('publish-repeat'),
                onPressed: _connected && _schema != null ? _startRepeating : null,
                icon: const Icon(Icons.repeat),
                label: Text(context.strings.repeatHz(_rateHz)),
              )),
        PopupMenuButton<int>(
          key: const Key('publish-rate'),
          tooltip: context.strings.repeatRate,
          enabled: !_repeating,
          icon: const Icon(Icons.speed),
          initialValue: _rateHz,
          onSelected: (rate) => setState(() => _rateHz = rate),
          itemBuilder: (_) => [for (final r in const [1, 2, 5, 10, 20]) PopupMenuItem(value: r, child: Text('$r Hz'))],
        ),
      ]),
    )),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final typeOptions = {
      ..._types,
      ..._localDefinitions.keys,
      ?_selectedType,
    }.toList()..sort();
    return Scaffold(
      appBar: AppBar(
        title: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft,
          child: Text(context.strings.publishMessage, style: const TextStyle(fontWeight: FontWeight.w800))),
        actions: [
          IconButton(
            tooltip: context.strings.refreshRobotTopics,
            onPressed: _connected && !_loadingTopics ? _discoverTopics : null,
            icon: _loadingTopics
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'add') _addCustomType();
              if (value == 'manage') _manageCustomTypes();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'add',
                child: ListTile(
                  leading: Icon(Icons.add),
                  title: Text(context.strings.addCustomTypeShort),
                ),
              ),
              PopupMenuItem(
                value: 'manage',
                child: ListTile(
                  leading: Icon(Icons.tune),
                  title: Text(context.strings.manageCustomTypes),
                ),
              ),
            ],
          ),
        ],
      ),
      // Publish controls stay on screen however long the message form is.
      bottomNavigationBar: _selectedType == null ? null : _actionBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Only worth a banner while it is not simply connected and ready.
                    if (!_connected || _loadingTopics) ...[
                      _ConnectionBanner(
                        connected: _connected,
                        loadingTopics: _loadingTopics,
                      ),
                      const SizedBox(height: 20),
                    ],
                    Text(
                      context.strings.composeMessage,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.strings.composeHelp,
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 20),
                    RawAutocomplete<String>(
                      textEditingController: _topicController,
                      focusNode: _topicFocus,
                      displayStringForOption: (option) => option,
                      optionsBuilder: (value) {
                        final query = value.text.trim().toLowerCase();
                        if (query.isEmpty) return _topics.take(30);
                        return _topics
                            .where(
                              (topic) => topic.toLowerCase().contains(query),
                            )
                            .take(30);
                      },
                      onSelected: _selectTopic,
                      fieldViewBuilder:
                          (context, controller, focusNode, onSubmitted) =>
                              TextFormField(
                                key: const Key('publish-topic'),
                                controller: controller,
                                focusNode: focusNode,
                                enabled: !_repeating,
                                decoration: InputDecoration(
                                  labelText: context.strings.topicName,
                                  hintText: '/my_topic',
                                  prefixIcon: const Icon(Icons.topic_outlined),
                                  suffixIcon: _topics.isEmpty
                                      ? null
                                      : const Icon(Icons.arrow_drop_down),
                                ),
                                validator: (value) =>
                                    value == null ||
                                        value.trim().isEmpty ||
                                        RegExp(r'\s').hasMatch(value)
                                    ? context.strings.topicNoSpaces
                                    : null,
                              ),
                      optionsViewBuilder: (context, onSelected, options) =>
                          Align(
                            alignment: Alignment.topLeft,
                            child: Material(
                              elevation: 6,
                              borderRadius: BorderRadius.circular(12),
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxHeight: 280,
                                  maxWidth: 760,
                                ),
                                child: ListView.builder(
                                  padding: EdgeInsets.zero,
                                  shrinkWrap: true,
                                  itemCount: options.length,
                                  itemBuilder: (context, index) {
                                    final topic = options.elementAt(index);
                                    return ListTile(
                                      dense: true,
                                      title: Text(topic),
                                      subtitle: _topicTypes[topic] == null
                                          ? null
                                          : Text(_topicTypes[topic]!),
                                      onTap: () => onSelected(topic),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                    ),
                    const SizedBox(height: 14),
                    DropdownButtonFormField<String>(
                      key: ValueKey(_selectedType),
                      initialValue: _selectedType,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: context.strings.messageType,
                        prefixIcon: Icon(Icons.data_object),
                      ),
                      items: typeOptions
                          .map(
                            (type) => DropdownMenuItem(
                              value: type,
                              child: Text(
                                type,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      validator: (value) =>
                          value == null ? context.strings.selectMessageType : null,
                      onChanged: _repeating ? null : _selectType,
                    ),
                    if (_selectedType != null) ...[
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              context.strings.messageContent,
                              style: theme.textTheme.labelLarge?.copyWith(
                                letterSpacing: 1.1,
                              ),
                            ),
                          ),
                          SegmentedButton<bool>(
                            segments: [
                              ButtonSegment(
                                value: false,
                                label: Text(context.strings.form),
                                icon: Icon(Icons.tune),
                              ),
                              ButtonSegment(
                                value: true,
                                label: Text('JSON'),
                                icon: Icon(Icons.code),
                              ),
                            ],
                            selected: {_jsonMode},
                            showSelectedIcon: false,
                            onSelectionChanged: _repeating
                                ? null
                                : (_) => _toggleJsonMode(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_loadingSchema)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      else if (_schema == null)
                        Text(
                          context.strings.definitionUnavailable,
                        )
                      else if (_jsonMode)
                        TextFormField(
                          key: const Key('publish-json'),
                          controller: _jsonController,
                          enabled: !_repeating,
                          minLines: 10,
                          maxLines: 24,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                          decoration: InputDecoration(
                            labelText: context.strings.messageJson,
                            alignLabelWithHint: true,
                            helperText:
                                context.strings.jsonCheckedHelp,
                          ),
                          validator: (value) {
                            try {
                              _schema!.coerce(jsonDecode(value ?? ''));
                              return null;
                            } catch (error) {
                              return error is FormatException
                                  ? error.message.toString()
                                  : context.strings.enterValidJson;
                            }
                          },
                        )
                      else
                        _buildFields(_schema!.root),
                    ],
                    if (_status != null) ...[
                      const SizedBox(height: 18),
                      StatusPanel(
                        title: _statusIsError
                            ? context.strings.needsAttention
                            : context.strings.publishStatus,
                        message: _status!,
                        isError: _statusIsError,
                      ),
                    ],
                    if (_recent.isNotEmpty) ...[
                      const SizedBox(height: 22),
                      Text(
                        context.strings.recentMessages,
                        style: theme.textTheme.labelLarge?.copyWith(
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 8),
                      for (final item in _recent.take(3))
                        Card(
                          child: ExpansionTile(
                            title: Text(
                              item.topic,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              item.type,
                              overflow: TextOverflow.ellipsis,
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: SelectableText(
                                  item.preview,
                                  style: const TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({
    required this.connected,
    required this.loadingTopics,
  });
  final bool connected;
  final bool loadingTopics;

  @override
  Widget build(BuildContext context) {
    final color = connected
        ? const Color(0xFF18865B)
        : Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(connected ? Icons.wifi : Icons.wifi_off, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              connected
                  ? (loadingTopics
                        ? context.strings.connectedLoadingTopics
                        : context.strings.connectedToRobot)
                  : context.strings.connectingToRobot,
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          if (loadingTopics)
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            ),
        ],
      ),
    );
  }
}
