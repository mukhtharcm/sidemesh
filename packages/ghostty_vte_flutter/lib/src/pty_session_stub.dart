import 'dart:async';
import 'dart:typed_data';

import 'pty_session_types.dart';

/// Web stub for the native PTY session API.
final class GhosttyTerminalPtySession {
  GhosttyTerminalPtySession({
    GhosttyTerminalPtySessionConfig config =
        const GhosttyTerminalPtySessionConfig(),
  }) : _rows = config.rows,
       _cols = config.cols;

  final _events = StreamController<GhosttyTerminalPtySessionEvent>.broadcast();
  GhosttyTerminalPtySessionState _state = GhosttyTerminalPtySessionState.idle;
  int? _exitCode;
  int _rows;
  int _cols;

  Stream<GhosttyTerminalPtySessionEvent> get events => _events.stream;
  GhosttyTerminalPtySessionState get state => _state;
  int? get exitCode => _exitCode;
  ({int rows, int cols}) get size => (rows: _rows, cols: _cols);
  Object? get pty => null;

  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    throw UnsupportedError(
      'GhosttyTerminalPtySession is only available on native platforms.',
    );
  }

  int write(String text) {
    return 0;
  }

  int writeBytes(Uint8List data) {
    return 0;
  }

  void resize({required int rows, required int cols}) {
    _rows = rows;
    _cols = cols;
  }

  void close() {
    if (_state == GhosttyTerminalPtySessionState.closed) {
      return;
    }
    final previous = _state;
    _state = GhosttyTerminalPtySessionState.closed;
    _events.add(GhosttyTerminalPtyStateChangeEvent(previous, _state));
    unawaited(_events.close());
  }
}
