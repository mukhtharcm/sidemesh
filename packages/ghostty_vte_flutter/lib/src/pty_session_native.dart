import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:portable_pty/portable_pty.dart';

import 'pty_session_types.dart';

final _libc = ffi.DynamicLibrary.process();

typedef _FcntlNative = ffi.Int32 Function(ffi.Int32, ffi.Int32, ffi.Int32);
typedef _FcntlDart = int Function(int, int, int);

const _fGetfl = 3;
const _fSetfl = 4;
final int _oNonblock = (Platform.isMacOS || Platform.isIOS) ? 0x0004 : 0x0800;

bool _setNonBlocking(int fd) {
  if (fd < 0) {
    return false;
  }
  try {
    final fcntl = _libc.lookupFunction<_FcntlNative, _FcntlDart>('fcntl');
    final flags = fcntl(fd, _fGetfl, 0);
    if (flags < 0) {
      return false;
    }
    return fcntl(fd, _fSetfl, flags | _oNonblock) >= 0;
  } catch (_) {
    return false;
  }
}

/// Owns a single PTY process and streams raw output chunks.
final class GhosttyTerminalPtySession {
  GhosttyTerminalPtySession({
    GhosttyTerminalPtySessionConfig config =
        const GhosttyTerminalPtySessionConfig(),
  }) : _config = config,
       _rows = config.rows,
       _cols = config.cols;

  final GhosttyTerminalPtySessionConfig _config;
  final _events = StreamController<GhosttyTerminalPtySessionEvent>.broadcast();

  PortablePty? _pty;
  Timer? _readTimer;
  GhosttyTerminalPtySessionState _state = GhosttyTerminalPtySessionState.idle;
  int? _exitCode;
  int _rows;
  int _cols;

  Stream<GhosttyTerminalPtySessionEvent> get events => _events.stream;
  GhosttyTerminalPtySessionState get state => _state;
  int? get exitCode => _exitCode;
  ({int rows, int cols}) get size => (rows: _rows, cols: _cols);
  PortablePty? get pty => _pty;

  void spawn(
    String command, {
    List<String>? args,
    Map<String, String>? environment,
  }) {
    if (_state == GhosttyTerminalPtySessionState.closed) {
      throw StateError('Session is closed.');
    }
    if (_state == GhosttyTerminalPtySessionState.running) {
      throw StateError('Process already running.');
    }

    _closePty();
    _exitCode = null;
    _rows = _config.rows;
    _cols = _config.cols;

    final pty = PortablePty.open(
      rows: _rows,
      cols: _cols,
      transport: _config.transport,
    );
    _pty = pty;
    pty.spawn(command, args: args, environment: environment);
    _setNonBlocking(pty.masterFd);
    _setState(GhosttyTerminalPtySessionState.running);
    _startReadLoop();
  }

  int write(String text) {
    final pty = _pty;
    if (_state != GhosttyTerminalPtySessionState.running || pty == null) {
      return 0;
    }
    try {
      return pty.writeString(text);
    } catch (error, stackTrace) {
      _events.add(GhosttyTerminalPtyErrorEvent(error, stackTrace));
      return 0;
    }
  }

  int writeBytes(Uint8List data) {
    final pty = _pty;
    if (_state != GhosttyTerminalPtySessionState.running || pty == null) {
      return 0;
    }
    try {
      return pty.writeBytes(data);
    } catch (error, stackTrace) {
      _events.add(GhosttyTerminalPtyErrorEvent(error, stackTrace));
      return 0;
    }
  }

  void resize({required int rows, required int cols}) {
    final pty = _pty;
    _rows = rows;
    _cols = cols;
    if (_state != GhosttyTerminalPtySessionState.running || pty == null) {
      return;
    }
    try {
      pty.resize(rows: rows, cols: cols);
    } catch (error, stackTrace) {
      _events.add(GhosttyTerminalPtyErrorEvent(error, stackTrace));
    }
  }

  void close() {
    if (_state == GhosttyTerminalPtySessionState.closed) {
      return;
    }
    _readTimer?.cancel();
    _readTimer = null;
    _closePty();
    _setState(GhosttyTerminalPtySessionState.closed);
    unawaited(_events.close());
  }

  void _startReadLoop() {
    _readTimer?.cancel();
    _readTimer = Timer.periodic(_config.pollInterval, (_) => _pollRead());
  }

  void _pollRead() {
    final pty = _pty;
    if (_state != GhosttyTerminalPtySessionState.running || pty == null) {
      return;
    }

    final exited = pty.tryWait();
    if (exited != null) {
      _handleExit(exited);
      return;
    }

    while (true) {
      try {
        final bytes = pty.readSync(_config.readChunkSize);
        if (bytes.isEmpty) {
          break;
        }
        _events.add(GhosttyTerminalPtyOutputEvent(bytes));
        if (bytes.length < _config.readChunkSize) {
          break;
        }
      } on StateError {
        break;
      } catch (error, stackTrace) {
        _events.add(GhosttyTerminalPtyErrorEvent(error, stackTrace));
        break;
      }
    }

    final exitAfterRead = pty.tryWait();
    if (exitAfterRead != null) {
      _handleExit(exitAfterRead);
    }
  }

  void _handleExit(int exitCode) {
    if (_state != GhosttyTerminalPtySessionState.running) {
      return;
    }
    _readTimer?.cancel();
    _readTimer = null;
    _exitCode = exitCode;
    _setState(GhosttyTerminalPtySessionState.exited);
    _events.add(GhosttyTerminalPtyExitEvent(exitCode));
  }

  void _closePty() {
    final pty = _pty;
    _pty = null;
    if (pty == null) {
      return;
    }
    try {
      if (pty.tryWait() == null) {
        try {
          pty.kill();
        } catch (_) {
          // The child may already have exited between tryWait and kill.
        }
      }
    } finally {
      pty.close();
    }
  }

  void _setState(GhosttyTerminalPtySessionState next) {
    if (_state == next) {
      return;
    }
    final previous = _state;
    _state = next;
    _events.add(GhosttyTerminalPtyStateChangeEvent(previous, next));
  }
}
