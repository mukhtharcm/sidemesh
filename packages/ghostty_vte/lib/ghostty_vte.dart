/// Public entrypoint for ghostty_vte bindings.
///
/// Provides a Dart API for Ghostty's terminal VT parser, including OSC
/// and SGR parsing, keyboard encoding, and paste safety checks.
///
/// ```dart
/// import 'package:ghostty_vte/ghostty_vte.dart';
///
/// // Check if clipboard content is safe to paste
/// if (GhosttyVt.isPasteSafe(clipboardText)) {
///   terminal.write(clipboardText);
/// }
///
/// // Parse SGR attributes
/// final sgr = GhosttyVt.newSgrParser();
/// final attrs = sgr.parseParams([1, 31]); // bold, red
/// sgr.close();
/// ```
library;

/// Platform-resolved VT parser and emitter API.
///
/// On native targets this exports the FFI-backed implementation; on web
/// targets it exports the wasm/JS-interop variant.
export 'src/api_native.dart' if (dart.library.js_interop) 'src/api_web.dart';
