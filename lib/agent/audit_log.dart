import 'package:flutter/foundation.dart';

enum AuditKind {
  /// What the person asked.
  instruction,
  /// What the model planned or said.
  plan,
  /// A skill call that passed validation and ran.
  call,
  /// A skill call the validator refused.
  rejected,
  /// The outcome of a call.
  result,
  /// Anything else worth keeping (backend errors, interruptions).
  note,
}

class AuditEntry {
  AuditEntry(this.kind, this.text, {this.ok, this.source, this.image, DateTime? time})
      : time = time ?? DateTime.now();

  /// A picture that went with this step (what the camera showed for `look`).
  final Uint8List? image;

  final DateTime time;
  final AuditKind kind;
  final String text;
  /// For results: whether the call succeeded.
  final bool? ok;
  /// Which backend produced a plan (e.g. "cloud", "local"), or "person" for instructions.
  final String? source;

  @override
  String toString() => '${time.toIso8601String()} ${kind.name}${source == null ? '' : '[$source]'}'
      '${ok == null ? '' : ok! ? ' ok' : ' failed'}: $text';
}

/// Everything the agent did and why, newest last. The UI shows it; nothing is sent anywhere.
class AuditLog extends ChangeNotifier {
  AuditLog({this.capacity = 300});

  final int capacity;
  final _entries = <AuditEntry>[];

  List<AuditEntry> get entries => List.unmodifiable(_entries);

  void add(AuditEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) _entries.removeRange(0, _entries.length - capacity);
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
