/// Native-only API entrypoint for ghostty terminal bindings.
///
/// This module exports generated FFI declarations, the main high-level helpers, and
/// the wasm support stub (unused natively, but part of the public surface).
library;

export '../ghostty_vte_bindings_generated.dart';

/// High-level terminal helpers and key event/OSC/SGR parsers.
export 'high_level.dart';

/// Stubbed wasm API for consistency with web builds.
export 'wasm_support_stub.dart';
