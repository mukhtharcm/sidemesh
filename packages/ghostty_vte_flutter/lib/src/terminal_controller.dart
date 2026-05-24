/// Cross-platform terminal controller selection.
///
/// Uses [terminal_controller_native.dart] on non-web targets and
/// [terminal_controller_web.dart] on web.
library;

export 'terminal_controller_native.dart'
    if (dart.library.js_interop) 'terminal_controller_web.dart';
