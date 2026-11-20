/// The token of a password reset link the web page was opened with (see web/index.html), once.
/// Other platforms open reset links in the browser, so they have none.
library;

export 'recovery_link_stub.dart' if (dart.library.js_interop) 'recovery_link_web.dart';
