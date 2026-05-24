import 'dart:typed_data';

import 'pty_transport.dart';

enum GhosttyTerminalPtySessionState { idle, running, exited, closed }

sealed class GhosttyTerminalPtySessionEvent {
  const GhosttyTerminalPtySessionEvent();
}

final class GhosttyTerminalPtyOutputEvent
    extends GhosttyTerminalPtySessionEvent {
  const GhosttyTerminalPtyOutputEvent(this.data);

  final Uint8List data;
}

final class GhosttyTerminalPtyExitEvent extends GhosttyTerminalPtySessionEvent {
  const GhosttyTerminalPtyExitEvent(this.exitCode);

  final int exitCode;
}

final class GhosttyTerminalPtyErrorEvent
    extends GhosttyTerminalPtySessionEvent {
  const GhosttyTerminalPtyErrorEvent(this.error, [this.stackTrace]);

  final Object error;
  final StackTrace? stackTrace;
}

final class GhosttyTerminalPtyStateChangeEvent
    extends GhosttyTerminalPtySessionEvent {
  const GhosttyTerminalPtyStateChangeEvent(this.previous, this.current);

  final GhosttyTerminalPtySessionState previous;
  final GhosttyTerminalPtySessionState current;
}

final class GhosttyTerminalPtySessionConfig {
  const GhosttyTerminalPtySessionConfig({
    this.rows = 24,
    this.cols = 80,
    this.readChunkSize = 4096,
    this.pollInterval = const Duration(milliseconds: 10),
    this.transport,
  });

  final int rows;
  final int cols;
  final int readChunkSize;
  final Duration pollInterval;
  final GhosttyTerminalPtyTransport? transport;
}
