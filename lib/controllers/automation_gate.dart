/// Serializes automation on one robot, including time spent waiting for a model or between rounds.
/// Other robots have their own gate. A stop invalidates the owner before calling its stop handler.
class AutomationGate {
  Object? _owner;
  void Function()? _stop;
  bool _closed = false;

  bool ownedBy(Object owner) => identical(_owner, owner);

  bool acquire(Object owner, void Function() stop) {
    if (_closed || _owner != null) return false;
    _owner = owner;
    _stop = stop;
    return true;
  }

  void release(Object owner) {
    if (!ownedBy(owner)) return;
    _owner = null;
    _stop = null;
  }

  void interrupt([Object? requester]) {
    final owner = _owner, stop = _stop;
    _owner = null;
    _stop = null;
    if (owner != null && !identical(owner, requester)) stop?.call();
  }

  void close() {
    _closed = true;
    interrupt();
  }
}
