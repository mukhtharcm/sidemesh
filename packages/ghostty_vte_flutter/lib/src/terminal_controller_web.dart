import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'pty_session.dart';
import 'shell_launch.dart';
import 'terminal_render_model.dart';
import 'terminal_snapshot.dart';
import 'terminal_surface_contract.dart';

/// Web-compatible terminal controller.
///
/// This keeps a real [VtTerminal] alive on web but does not spawn local
/// processes. It is intended to be connected to a remote transport by feeding
/// output via [appendDebugOutput] and sending input through [write]/[sendKey].
class GhosttyTerminalController extends ChangeNotifier
    implements GhosttyTerminalSessionController {
  GhosttyTerminalController({
    this.maxLines = 2000,
    this.maxScrollback = 10_000,
    this.initialCols = 80,
    this.initialRows = 24,
    this.preferPty = true,
    this.defaultShell,
  }) : assert(maxLines > 0),
       assert(maxScrollback >= 0),
       assert(initialCols > 0),
       assert(initialRows > 0),
       _cols = initialCols,
       _rows = initialRows;

  /// Maximum retained line count in the formatted terminal snapshot.
  final int maxLines;

  /// Maximum terminal scrollback depth retained by [VtTerminal].
  final int maxScrollback;

  /// Initial terminal width in cells before the view reports a real size.
  final int initialCols;

  /// Initial terminal height in cells before the view reports a real size.
  final int initialRows;

  /// Optional shell hint for transport-backed terminals.
  /// Placeholder for API parity with native controller construction.
  final bool preferPty;

  /// Optional shell hint for remote backends.
  final String? defaultShell;

  VtTerminal? _terminal;
  VtTerminalFormatter? _plainFormatter;
  VtTerminalFormatter? _styledFormatter;
  VtKeyEncoder? _encoder;
  VtMouseEncoder? _mouseEncoder;
  GhosttyTerminalShellLaunch? _activeShellLaunch;
  bool Function(List<int> bytes)? _externalWriteBytes;
  void Function(int cols, int rows, int cellWidthPx, int cellHeightPx)?
  _externalResize;

  final List<String> _lines = <String>[''];
  String _plainText = '';
  GhosttyTerminalSnapshot _snapshot = const GhosttyTerminalSnapshot.empty();
  String _title = 'Terminal (Web)';
  bool _running = false;
  int _revision = 0;
  int _cols;
  int _rows;

  /// Monotonic value that increments whenever buffered output/state changes.
  @override
  int get revision => _revision;

  /// Terminal title derived from OSC title updates when present.
  @override
  String get title => _title;

  /// Whether the controller currently considers the remote session active.
  @override
  bool get isRunning => _running;

  /// Current terminal width in cells.
  @override
  int get cols => _cols;

  /// Current terminal height in cells.
  @override
  int get rows => _rows;

  /// Live VT terminal state backing this controller.
  VtTerminal get terminal => _ensureTerminal();

  /// Current formatted plain-text terminal snapshot.
  String get plainText => _plainText;

  /// Current styled terminal snapshot used by [GhosttyTerminalView].
  GhosttyTerminalSnapshot get snapshot => _snapshot;

  /// Web does not expose a native Ghostty render-state snapshot.
  GhosttyTerminalRenderSnapshot? get renderSnapshot => null;

  /// Current buffered terminal lines.
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// Number of buffered lines.
  int get lineCount => _lines.length;

  /// Most recent launch metadata associated with this controller.
  GhosttyTerminalShellLaunch? get activeShellLaunch => _activeShellLaunch;

  /// Web does not expose a local PTY session.
  GhosttyTerminalPtySession? get ptySession => null;

  /// Optional observer callback invoked whenever the VT engine needs to send
  /// data back to the PTY (e.g. DSR responses, DA replies).
  ///
  /// On web this is never called since the web controller does not wire
  /// [VtTerminal.onWritePty]. It exists for API parity with the native
  /// controller.
  void Function(Uint8List data)? onWritePtyData;

  /// Not called on web — exists for API parity with the native controller.
  void Function()? onBellData;

  /// Not called on web — exists for API parity with the native controller.
  void Function()? onTitleChangedData;

  /// Not called on web — exists for API parity with the native controller.
  VtSizeReportSize? Function()? onSizeQueryData;

  /// Not called on web — exists for API parity with the native controller.
  GhosttyColorScheme? Function()? onColorSchemeQueryData;

  /// Not called on web — exists for API parity with the native controller.
  VtDeviceAttributes? Function()? onDeviceAttributesQueryData;

  /// Not called on web — exists for API parity with the native controller.
  Uint8List Function()? onEnquiryData;

  /// Not called on web — exists for API parity with the native controller.
  String Function()? onXtversionData;

  VtTerminal _ensureTerminal() {
    final existing = _terminal;
    if (existing != null) {
      return existing;
    }

    final terminal = GhosttyVt.newTerminal(
      cols: _cols,
      rows: _rows,
      maxScrollback: maxScrollback,
    );
    final formatter = terminal.createFormatter();
    final styledFormatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        trim: false,
        extra: VtFormatterTerminalExtra.all(),
      ),
    );
    _terminal = terminal;
    _plainFormatter = formatter;
    _styledFormatter = styledFormatter;
    _refreshSnapshot();
    return terminal;
  }

  /// Returns a formatted terminal snapshot using the requested formatter mode.
  String formatTerminal({
    GhosttyFormatterFormat emit =
        GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
    bool unwrap = false,
    bool trim = true,
    VtFormatterTerminalExtra extra = const VtFormatterTerminalExtra(),
  }) {
    final terminal = _ensureTerminal();
    final formatter = terminal.createFormatter(
      VtFormatterTerminalOptions(
        emit: emit,
        unwrap: unwrap,
        trim: trim,
        extra: extra,
      ),
    );
    try {
      return formatter.formatText();
    } finally {
      formatter.close();
    }
  }

  /// Marks the transport session as started and records launch metadata.
  Future<void> start({
    String? shell,
    List<String> arguments = const <String>[],
    Map<String, String>? environment,
  }) async {
    if (_running) {
      return;
    }
    _ensureTerminal();
    final resolvedShell = shell ?? defaultShell ?? 'web transport demo';
    _activeShellLaunch = GhosttyTerminalShellLaunch(
      label: resolvedShell,
      shell: resolvedShell,
      arguments: List<String>.unmodifiable(arguments),
      environment: environment == null
          ? null
          : Map<String, String>.unmodifiable(environment),
    );
    _running = true;
    _markDirty();
  }

  /// Starts a resolved launch plan and stores its metadata on the controller.
  Future<void> startLaunch(GhosttyTerminalShellLaunch launch) async {
    await start(
      shell: launch.shell,
      arguments: launch.arguments,
      environment: launch.environment,
    );
    _activeShellLaunch = GhosttyTerminalShellLaunch(
      label: launch.label,
      shell: launch.shell,
      arguments: List<String>.unmodifiable(launch.arguments),
      environment: launch.environment == null
          ? null
          : Map<String, String>.unmodifiable(launch.environment!),
      setupCommand: launch.setupCommand,
    );
    _markDirty();
  }

  /// Restarts the controller using a resolved launch plan.
  Future<void> restartLaunch(GhosttyTerminalShellLaunch launch) async {
    await stop();
    await startLaunch(launch);
  }

  /// Attach an external transport backend such as an SSH session.
  void attachExternalTransport({
    required bool Function(List<int> bytes) writeBytes,
    void Function(int cols, int rows, int cellWidthPx, int cellHeightPx)?
    onResize,
    GhosttyTerminalShellLaunch? launch,
  }) {
    _ensureTerminal();
    _externalWriteBytes = writeBytes;
    _externalResize = onResize;
    if (launch != null) {
      _activeShellLaunch = GhosttyTerminalShellLaunch(
        label: launch.label,
        shell: launch.shell,
        arguments: List<String>.unmodifiable(launch.arguments),
        environment: launch.environment == null
            ? null
            : Map<String, String>.unmodifiable(launch.environment!),
        setupCommand: launch.setupCommand,
      );
    }
    _running = true;
    _markDirty();
  }

  /// Detach any external transport backend.
  void detachExternalTransport() {
    _externalWriteBytes = null;
    _externalResize = null;
  }

  /// Inject remote output bytes directly into the VT stream.
  void appendOutputBytes(List<int> bytes) {
    if (bytes.isEmpty) return;
    _consumeOscText(utf8.decode(bytes, allowMalformed: true));
    _ensureTerminal().writeBytes(bytes);
    _refreshSnapshot();
    _markDirty();
  }

  /// Update the running state for an external transport session.
  void setSessionRunning(bool running) {
    _running = running;
    _markDirty();
  }

  /// Web keeps transport setup separate, so profile starts are a no-op wrapper.
  Future<GhosttyTerminalShellLaunch?> startShellProfile({
    required GhosttyTerminalShellProfile profile,
    Map<String, String>? platformEnvironment,
    Map<String, String> environmentOverrides = const <String, String>{
      'TERM': 'xterm-256color',
    },
  }) async {
    final launches = ghosttyTerminalShellLaunches(
      profile: profile,
      platformEnvironment: platformEnvironment,
      environmentOverrides: environmentOverrides,
    );
    if (launches.isNotEmpty) {
      await startLaunch(launches.first);
      return activeShellLaunch;
    }
    await start();
    return activeShellLaunch;
  }

  /// Marks the remote session inactive without clearing terminal contents.
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    _markDirty();
  }

  /// Clears terminal contents and scrollback while preserving dimensions.
  void clear() {
    final terminal = _terminal;
    if (terminal == null) {
      _lines
        ..clear()
        ..add('');
      _plainText = '';
      _markDirty();
      return;
    }

    terminal.reset();
    _refreshSnapshot();
    _markDirty();
  }

  /// Resizes the VT grid.
  @override
  void resize({
    required int cols,
    required int rows,
    int cellWidthPx = 0,
    int cellHeightPx = 0,
  }) {
    final checkedCols = cols.clamp(1, 0xFFFF);
    final checkedRows = rows.clamp(1, 0xFFFF);
    if (checkedCols == _cols && checkedRows == _rows) {
      return;
    }

    _cols = checkedCols;
    _rows = checkedRows;

    final terminal = _terminal;
    if (terminal != null) {
      terminal.resize(
        cols: checkedCols,
        rows: checkedRows,
        cellWidthPx: cellWidthPx,
        cellHeightPx: cellHeightPx,
      );
      _externalResize?.call(
        checkedCols,
        checkedRows,
        cellWidthPx,
        cellHeightPx,
      );
      _refreshSnapshot();
    }
    _markDirty();
  }

  /// Forwards text input to the remote transport abstraction.
  ///
  /// When [sanitizePaste] is true, unsafe multi-line paste payloads are rejected.
  @override
  bool write(String text, {bool sanitizePaste = false}) {
    if (!_running) {
      return false;
    }
    if (sanitizePaste && !GhosttyVt.isPasteSafe(text)) {
      return false;
    }
    final externalWriteBytes = _externalWriteBytes;
    if (externalWriteBytes == null) {
      return false;
    }
    return externalWriteBytes(utf8.encode(text));
  }

  /// Forwards already-encoded bytes to the remote transport abstraction.
  @override
  bool writeBytes(List<int> bytes) {
    if (!_running) {
      return false;
    }
    final externalWriteBytes = _externalWriteBytes;
    if (externalWriteBytes == null) {
      return false;
    }
    return externalWriteBytes(bytes);
  }

  /// Encodes a key event using Ghostty's keyboard protocol rules.
  ///
  /// The encoded bytes are returned to the caller indirectly as a success flag;
  /// a real transport is expected to send them to the remote endpoint.
  bool sendKey({
    required GhosttyKey key,
    GhosttyKeyAction action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
    int mods = 0,
    int consumedMods = 0,
    bool composing = false,
    String utf8Text = '',
    int unshiftedCodepoint = 0,
  }) {
    if (!_running) {
      return false;
    }

    _encoder ??= VtKeyEncoder();
    final terminal = _terminal;
    if (terminal != null) {
      _encoder!.setOptionsFromTerminal(terminal);
    }

    final event = VtKeyEvent()
      ..action = action
      ..key = key
      ..mods = mods
      ..consumedMods = consumedMods
      ..composing = composing
      ..utf8Text = utf8Text
      ..unshiftedCodepoint = unshiftedCodepoint;
    final encoded = _encoder!.encode(event);
    event.close();
    return encoded.isNotEmpty && writeBytes(encoded);
  }

  /// Encodes a mouse event using Ghostty's mouse protocol rules.
  bool sendMouse({
    required GhosttyMouseAction action,
    GhosttyMouseButton? button,
    int mods = 0,
    required VtMousePosition position,
    required VtMouseEncoderSize size,
    GhosttyMouseTrackingMode? trackingMode,
    GhosttyMouseFormat? format,
    bool? anyButtonPressed,
    bool? trackLastCell,
  }) {
    if (!_running) {
      return false;
    }

    _mouseEncoder ??= VtMouseEncoder();
    final terminal = _terminal;
    if (terminal != null) {
      _mouseEncoder!.setOptionsFromTerminal(terminal);
    }
    if (trackingMode != null ||
        format != null ||
        anyButtonPressed != null ||
        trackLastCell != null) {
      VtMouseEncoderOptions(
        trackingMode:
            trackingMode ??
            GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL,
        format: format ?? GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR,
        size: size,
        anyButtonPressed: anyButtonPressed ?? false,
        trackLastCell: trackLastCell ?? true,
      ).applyTo(_mouseEncoder!);
    } else {
      _mouseEncoder!.size = size;
    }

    final event = VtMouseEvent()
      ..action = action
      ..button = button
      ..mods = mods
      ..position = position;
    final encoded = _mouseEncoder!.encode(event);
    event.close();
    return encoded.isNotEmpty && writeBytes(encoded);
  }

  /// Injects decoded terminal output directly into the VT model.
  ///
  /// This is primarily intended for demos and tests that emulate a remote
  /// terminal transport in memory.
  void appendDebugOutput(String text) {
    if (text.isEmpty) {
      return;
    }
    _consumeOscText(text);
    _ensureTerminal().write(text);
    _refreshSnapshot();
    _markDirty();
  }

  void _consumeOscText(String text) {
    for (final match in _oscRegex.allMatches(text)) {
      final payload = match.group(1);
      if (payload == null || payload.isEmpty) {
        continue;
      }
      final separator = payload.indexOf(';');
      if (separator <= 0 || separator >= payload.length - 1) {
        continue;
      }
      final code = payload.substring(0, separator);
      final data = payload.substring(separator + 1);
      if ((code == '0' || code == '2') && data.isNotEmpty) {
        _title = data;
      }
    }
  }

  void _refreshSnapshot() {
    final formatter = _plainFormatter;
    final styledFormatter = _styledFormatter;
    if (formatter == null || styledFormatter == null) {
      _plainText = '';
      _lines
        ..clear()
        ..add('');
      _snapshot = const GhosttyTerminalSnapshot.empty();
      return;
    }

    final text = formatter.formatText();
    _plainText = text;

    final parts = text.isEmpty ? <String>[''] : text.split('\n');
    _lines
      ..clear()
      ..addAll(
        parts.length > maxLines
            ? parts.sublist(parts.length - maxLines)
            : parts,
      );
    if (_lines.isEmpty) {
      _lines.add('');
    }
    _snapshot = GhosttyTerminalSnapshot.fromFormattedVt(
      styledFormatter.formatText(),
      maxLines: maxLines,
    );
  }

  void _markDirty() {
    _revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _encoder?.close();
    _mouseEncoder?.close();
    _styledFormatter?.close();
    _plainFormatter?.close();
    _terminal?.close();
    _running = false;
    super.dispose();
  }
}

final RegExp _oscRegex = RegExp(r'\x1b\]([^\x07\x1b]*)(?:\x07|\x1b\\)');
