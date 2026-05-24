import 'dart:typed_data';

/// Non-web stub for wasm initialization API.
///
/// The stub mirrors the web API shape so callers can use a single init call
/// path and fail loudly when not supported.
final class GhosttyVtWasm {
  const GhosttyVtWasm._();

  static bool get isInitialized => false;

  static Future<void> initializeFromBytes(Uint8List wasmBytes) async {
    throw UnsupportedError('GhosttyVtWasm is only available on web targets.');
  }
}
