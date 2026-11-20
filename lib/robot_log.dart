import 'dart:async';

import 'package:flutter/foundation.dart';

import 'ros_client.dart';

/// How serious a log line is, the same for ROS 1 and ROS 2.
enum LogLevel { debug, info, warn, error, fatal }

extension LogLevelLabel on LogLevel {
  String get label => switch (this) {
    LogLevel.debug => 'Debug', LogLevel.info => 'Info', LogLevel.warn => 'Warning',
    LogLevel.error => 'Error', LogLevel.fatal => 'Fatal',
  };
  bool get isProblem => index >= LogLevel.warn.index;
}

/// ROS 2 (rcl_interfaces/Log: 10, 20, 30, 40, 50) and ROS 1 (rosgraph_msgs/Log: 1, 2, 4, 8, 16) levels.
LogLevel logLevelOf(Object? value) {
  final v = value is num ? value.toInt() : int.tryParse('$value') ?? 20;
  return switch (v) {
    1 => LogLevel.debug, 2 => LogLevel.info, 4 => LogLevel.warn, 8 => LogLevel.error, 16 => LogLevel.fatal,
    <= 10 => LogLevel.debug, <= 20 => LogLevel.info, <= 30 => LogLevel.warn, <= 40 => LogLevel.error,
    _ => LogLevel.fatal,
  };
}

/// One log line, or several identical ones folded together ([count]).
class LogEntry {
  LogEntry({required this.level, required this.node, required this.text, required this.time,
    this.file = '', this.function = '', this.line = 0, this.count = 1});

  final LogLevel level;
  /// The logger, usually the node name (`amcl`, `robot1.controller_server`).
  final String node;
  /// The latest wording (folded repeats may differ in their numbers).
  String text;
  /// When it was last seen (the robot's clock when it says, else the phone's).
  DateTime time;
  final String file, function;
  final int line;
  int count;

  /// From a /rosout message of either ROS version; null if it is not one.
  static LogEntry? parse(Map msg, {DateTime? received}) {
    final text = msg['msg'];
    if (text is! String) return null;
    final stamp = (msg['stamp'] ?? (msg['header'] is Map ? msg['header']['stamp'] : null));
    DateTime? time;
    if (stamp is Map) {
      final sec = stamp['sec'] ?? stamp['secs'], nsec = stamp['nanosec'] ?? stamp['nsecs'] ?? 0;
      if (sec is num && sec > 0) {
        time = DateTime.fromMicrosecondsSinceEpoch(sec.toInt() * 1000000 + (nsec as num).toInt() ~/ 1000);
      }
    }
    return LogEntry(level: logLevelOf(msg['level']), node: '${msg['name'] ?? ''}'.replaceFirst(RegExp('^/'), ''),
        text: text.trimRight(), time: time ?? received ?? DateTime.now(), file: '${msg['file'] ?? ''}',
        function: '${msg['function'] ?? ''}', line: (msg['line'] as num?)?.toInt() ?? 0);
  }

  /// The same message, apart from numbers in it ("at time 968.78" and "at time 965.58" are one line
  /// repeating, as far as a person reading the log is concerned).
  bool sameAs(LogEntry o) => o.level == level && o.node == node && _shape(o.text) == _shape(text);

  static final _number = RegExp(r'\d+(\.\d+)?');
  static String _shape(String t) => t.replaceAll(_number, '#');

  /// One line for copying: `12:03:05 [Warning] amcl: text`.
  String toLine() => '${clock(time)} [${level.label}] $node: $text${count > 1 ? ' (x$count)' : ''}';

  static String clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = t.toLocal();
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }
}

/// The robot's log (/rosout) for the whole connection, collected from connect on so a problem that
/// happened before the log screen was opened is still there. Newest first; a line repeating one of the
/// recent ones is folded into it (and moves to the top), so a node that repeats itself does not bury
/// everything else.
class RobotLog extends ChangeNotifier {
  RobotLog(this.ros, {this.capacity = 2000});

  final RosClient ros;
  final int capacity;

  /// Newest first.
  final List<LogEntry> entries = [];
  /// Warnings and errors since the log screen was last looked at.
  int unseenProblems = 0;
  bool get started => _subs.isNotEmpty;
  /// True once any log line arrived.
  bool heard = false;

  final _subs = <StreamSubscription<Map<String, dynamic>>>[];
  Timer? _notify;

  /// Listens to /rosout, where every node of ROS 1 and ROS 2 publishes its log lines. Once.
  void start() {
    if (started) return;
    try {
      _subs.add(ros.subscribe('/rosout', queueLength: 50).listen(add, onError: (_) {}));
    } catch (_) {}
  }

  void add(Map<String, dynamic> msg) {
    final e = LogEntry.parse(msg);
    if (e == null) return;
    heard = true;
    // Fold into a recent identical line.
    for (var i = 0; i < entries.length && i < 30; i++) {
      final old = entries[i];
      if (!old.sameAs(e)) continue;
      old.count++;
      if (!e.time.isBefore(old.time)) {
        old.time = e.time;
        old.text = e.text;
      }
      if (i > 0) entries.insert(0, entries.removeAt(i));
      _changed(problem: false);
      return;
    }
    entries.insert(0, e);
    if (entries.length > capacity) entries.removeLast();
    _changed(problem: e.level.isProblem);
  }

  void markSeen() {
    if (unseenProblems == 0) return;
    unseenProblems = 0;
    notifyListeners();
  }

  void clear() {
    entries.clear();
    unseenProblems = 0;
    notifyListeners();
  }

  /// Counts by kind, for the summary.
  ({int errors, int warnings}) get problems {
    var errors = 0, warnings = 0;
    for (final e in entries) {
      if (e.level.index >= LogLevel.error.index) {
        errors++;
      } else if (e.level == LogLevel.warn) {
        warnings++;
      }
    }
    return (errors: errors, warnings: warnings);
  }

  /// Every node that logged, most active first.
  List<String> get nodes {
    final counts = <String, int>{};
    for (final e in entries) {
      counts[e.node] = (counts[e.node] ?? 0) + e.count;
    }
    return counts.keys.toList()..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  }

  // A chatty robot logs many lines a second: tell listeners at most ~5 times a second.
  void _changed({required bool problem}) {
    if (problem) unseenProblems++;
    _notify ??= Timer(const Duration(milliseconds: 200), () {
      _notify = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notify?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    super.dispose();
  }
}

/// Which lines the log screen shows.
enum LogFilter { all, warnings, errors }

bool logFilterMatches(LogFilter f, LogEntry e, {String? node, String query = ''}) {
  final level = switch (f) {
    LogFilter.all => true,
    LogFilter.warnings => e.level.isProblem,
    LogFilter.errors => e.level.index >= LogLevel.error.index,
  };
  if (!level || (node != null && e.node != node)) return false;
  if (query.isEmpty) return true;
  final q = query.toLowerCase();
  return e.text.toLowerCase().contains(q) || e.node.toLowerCase().contains(q);
}
