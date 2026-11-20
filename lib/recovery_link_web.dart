import 'dart:js_interop';

@JS('mobileRosRecovery')
external JSString? get _recovery;

@JS('mobileRosRecovery')
external set _recovery(JSString? value);

/// Reads and forgets the reset token web/index.html kept in memory.
String? takeRecoveryToken() {
  final token = _recovery?.toDart;
  _recovery = null;
  return token;
}
