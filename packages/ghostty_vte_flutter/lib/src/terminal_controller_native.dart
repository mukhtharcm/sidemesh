import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:ghostty_vte/ghostty_vte.dart';

import 'pty_session.dart';
import 'shell_launch.dart';
import 'terminal_render_model.dart';
import 'terminal_snapshot.dart';
import 'terminal_surface_contract.dart';

/// Controller for a terminal session backed by a subprocess.
///
/// On supported native platforms this prefers a shared PTY session backed by
/// `portable_pty`. If that is disabled, it falls back to a regular process.
///
/// Unlike the earlier preview-oriented controller, this controller keeps a real
/// [VtTerminal] alive and derives visible text from formatter snapshots so
/// cursor movement, clears, wrapping, and other VT semantics are preserved.
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

  /// Whether to attempt a native PTY launch when possible.
  final bool preferPty;

  /// Optional default shell path for [start].
  final String? defaultShell;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  StreamSubscription<int>? _exitSub;
  GhosttyTerminalPtySession? _ptySession;
  StreamSubscription<GhosttyTerminalPtySessionEvent>? _ptySessionSub;
  bool Function(List<int> bytes)? _externalWriteBytes;
  void Function(int cols, int rows, int cellWidthPx, int cellHeightPx)?
  _externalResize;

  VtTerminal? _terminal;
  VtTerminalFormatter? _plainFormatter;
  VtTerminalFormatter? _styledFormatter;
  VtTerminalFormatter? _unwrapFormatter;
  VtRenderState? _renderState;
  VtKeyEncoder? _encoder;
  VtMouseEncoder? _mouseEncoder;
  GhosttyTerminalShellLaunch? _activeShellLaunch;

  final List<String> _lines = <String>[''];
  String _plainText = '';
  GhosttyTerminalSnapshot _snapshot = const GhosttyTerminalSnapshot.empty();
  GhosttyTerminalRenderSnapshot? _renderSnapshot;
  String _title = 'Terminal';
  bool _running = false;
  bool _disposed = false;
  int _revision = 0;
  int _cols;
  int _rows;
  int _cellWidthPx = 0;
  int _cellHeightPx = 0;

  /// Monotonic value that increments whenever buffered output/state changes.
  @override
  int get revision => _revision;

  /// Terminal title (updated from OSC commands when available).
  @override
  String get title => _title;

  /// Whether a subprocess is currently active.
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

  /// Native Ghostty render-state snapshot for the live visible viewport.
  ///
  /// This is only available on native platforms and only reflects the current
  /// visible viewport, not formatter-derived scrollback transcript state.
  GhosttyTerminalRenderSnapshot? get renderSnapshot => _renderSnapshot;

  /// Most recent shell launch metadata associated with this controller.
  GhosttyTerminalShellLaunch? get activeShellLaunch => _activeShellLaunch;

  /// Active native PTY session when the shared PTY backend is in use.
  GhosttyTerminalPtySession? get ptySession => _ptySession;

  /// Optional observer callback invoked whenever the VT engine needs to send
  /// data back to the PTY (e.g. DSR responses, DA replies).
  ///
  /// This is called *after* the data has already been forwarded to the active
  /// process/PTY session. The [data] buffer is a copy and safe to retain.
  void Function(Uint8List data)? onWritePtyData;

  /// Optional observer callback invoked when the terminal receives a BEL
  /// character (0x07).
  void Function()? onBellData;

  /// Optional observer callback invoked when the terminal title changes
  /// via escape sequences (e.g. OSC 0 or OSC 2).
  void Function()? onTitleChangedData;

  /// Optional observer callback invoked when the terminal requests its
  /// size via XTWINOPS (CSI 14/16/18 t). Return a [VtSizeReportSize] to
  /// respond, or `null` to silently ignore.
  VtSizeReportSize? Function()? onSizeQueryData;

  /// Optional observer callback invoked when the terminal requests its
  /// color scheme via CSI ? 996 n. Return a [GhosttyColorScheme] to
  /// respond, or `null` to silently ignore.
  GhosttyColorScheme? Function()? onColorSchemeQueryData;

  /// Optional observer callback invoked when the terminal requests device
  /// attributes (DA1/DA2/DA3). Return a [VtDeviceAttributes] to respond,
  /// or `null` to silently ignore.
  VtDeviceAttributes? Function()? onDeviceAttributesQueryData;

  /// Optional observer callback invoked when the terminal receives an ENQ
  /// character (0x05). Return a [Uint8List] of response bytes.
  Uint8List Function()? onEnquiryData;

  /// Optional observer callback invoked when the terminal receives an
  /// XTVERSION query (CSI > q). Return a version string.
  String Function()? onXtversionData;

  /// Current buffered terminal lines.
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// Number of buffered lines.
  int get lineCount => _lines.length;

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

    // Forward terminal write-back data (DSR responses, mode queries, etc.)
    // to the PTY or process stdin so the host shell receives the replies.
    terminal.onWritePty = _onTerminalWritePty;

    // Wire effect callbacks, forwarding to the public observer properties.
    terminal.onBell = () => onBellData?.call();
    terminal.onTitleChanged = () {
      _title = terminal.title;
      onTitleChangedData?.call();
    };
    terminal.onSizeQuery = () => onSizeQueryData?.call();
    terminal.onColorSchemeQuery = () => onColorSchemeQueryData?.call();
    terminal.onDeviceAttributesQuery = () =>
        onDeviceAttributesQueryData?.call();
    terminal.onEnquiry = () => onEnquiryData?.call() ?? Uint8List(0);
    terminal.onXtversion = () => onXtversionData?.call() ?? '';

    final formatter = terminal.createFormatter();
    final styledFormatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        trim: false,
        extra: VtFormatterTerminalExtra.all(),
      ),
    );
    final unwrapFormatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(unwrap: true),
    );
    _terminal = terminal;
    _plainFormatter = formatter;
    _styledFormatter = styledFormatter;
    _unwrapFormatter = unwrapFormatter;
    _renderState = terminal.createRenderState();
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

  /// Starts a terminal subprocess.
  Future<void> start({
    String? shell,
    List<String> arguments = const <String>[],
    Map<String, String>? environment,
  }) async {
    if (_running) {
      return;
    }

    _ensureTerminal();

    final resolvedShell = shell ?? defaultShell ?? _defaultShell();
    _activeShellLaunch = _freezeLaunch(
      GhosttyTerminalShellLaunch(
        label: _shellLabel(resolvedShell),
        shell: resolvedShell,
        arguments: arguments,
        environment: environment,
      ),
    );

    if (_canUsePtyBackend()) {
      // Close any previous PTY session to avoid leaking file descriptors.
      _ptySessionSub?.cancel();
      _ptySession?.close();

      final session = GhosttyTerminalPtySession(
        config: GhosttyTerminalPtySessionConfig(rows: _rows, cols: _cols),
      );
      _ptySession = session;
      _ptySessionSub = session.events.listen(_onPtyEvent);
      session.spawn(resolvedShell, args: arguments, environment: environment);
      _running = true;
      _markDirty();
      return;
    }

    final process = await _spawnProcess(
      resolvedShell,
      arguments,
      environment: environment,
    );
    _process = process;
    _running = true;
    _markDirty();

    _stdoutSub = process.stdout.listen(_onProcessBytes);
    _stderrSub = process.stderr.listen(_onProcessBytes);
    _exitSub = process.exitCode.asStream().listen((exitCode) {
      _running = false;
      appendDebugOutput('\n[process exited: $exitCode]\n');
      _markDirty();
    });
  }

  void _onPtyEvent(GhosttyTerminalPtySessionEvent event) {
    switch (event) {
      case GhosttyTerminalPtyOutputEvent(:final data):
        _onProcessBytes(data);
      case GhosttyTerminalPtyExitEvent(:final exitCode):
        _running = false;
        appendDebugOutput('\n[process exited: $exitCode]\n');
        _markDirty();
      case GhosttyTerminalPtyErrorEvent():
        _markDirty();
      case GhosttyTerminalPtyStateChangeEvent(:final current):
        if (current != GhosttyTerminalPtySessionState.running) {
          _running = false;
        }
        _markDirty();
    }
  }

  /// Starts a resolved launch plan and stores its metadata on the controller.
  Future<void> startLaunch(GhosttyTerminalShellLaunch launch) async {
    await start(
      shell: launch.shell,
      arguments: launch.arguments,
      environment: launch.environment,
    );
    _activeShellLaunch = _freezeLaunch(launch);
    final setupCommand = launch.setupCommand;
    if (setupCommand != null && setupCommand.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      write(setupCommand);
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
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
      _activeShellLaunch = _freezeLaunch(launch);
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
    _ingestBytes(bytes);
  }

  /// Update the running state for an external transport session.
  void setSessionRunning(bool running) {
    _running = running;
    _markDirty();
  }

  /// Starts one of the shared shell profiles and returns the resolved launch.
  ///
  /// Returns `null` when no launch candidate was available or every candidate
  /// failed to start.
  Future<GhosttyTerminalShellLaunch?> startShellProfile({
    required GhosttyTerminalShellProfile profile,
    Map<String, String>? platformEnvironment,
    Map<String, String> environmentOverrides = const <String, String>{
      'TERM': 'xterm-256color',
    },
  }) async {
    Object? lastError;
    for (final launch in ghosttyTerminalShellLaunches(
      profile: profile,
      platformEnvironment: platformEnvironment,
      environmentOverrides: environmentOverrides,
    )) {
      try {
        await startLaunch(launch);
        return activeShellLaunch;
      } catch (error) {
        lastError = error;
        await stop();
      }
    }

    if (lastError != null) {
      appendDebugOutput('[shell profile failed: $lastError]\n');
    }
    return null;
  }

  /// Stops the subprocess if running.
  Future<void> stop() async {
    final process = _process;
    final session = _ptySession;
    if (process == null && session == null) {
      return;
    }

    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    await _exitSub?.cancel();
    await _ptySessionSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _exitSub = null;
    _ptySessionSub = null;

    process?.kill(ProcessSignal.sigterm);
    session?.close();
    _process = null;
    _ptySession = null;
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
  ///
  /// When [cellWidthPx] and [cellHeightPx] are non-zero they inform Ghostty of
  /// the physical pixel dimensions of each cell so that pixel-level size reports
  /// (e.g. CSI 14 t) return accurate values.
  @override
  void resize({
    required int cols,
    required int rows,
    int cellWidthPx = 0,
    int cellHeightPx = 0,
  }) {
    final checkedCols = cols.clamp(1, 0xFFFF);
    final checkedRows = rows.clamp(1, 0xFFFF);
    if (checkedCols == _cols &&
        checkedRows == _rows &&
        cellWidthPx == _cellWidthPx &&
        cellHeightPx == _cellHeightPx) {
      return;
    }

    _cols = checkedCols;
    _rows = checkedRows;
    _cellWidthPx = cellWidthPx;
    _cellHeightPx = cellHeightPx;

    final terminal = _terminal;
    if (terminal != null) {
      terminal.resize(
        cols: checkedCols,
        rows: checkedRows,
        cellWidthPx: cellWidthPx,
        cellHeightPx: cellHeightPx,
      );
      _ptySession?.resize(rows: checkedRows, cols: checkedCols);
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

  /// Writes text to terminal stdin.
  ///
  /// When [sanitizePaste] is true, unsafe multi-line paste payloads are rejected.
  @override
  bool write(String text, {bool sanitizePaste = false}) {
    if (sanitizePaste && !GhosttyVt.isPasteSafe(text)) {
      return false;
    }

    final session = _ptySession;
    if (session != null) {
      return session.write(text) > 0;
    }

    final process = _process;
    if (process == null) {
      final externalWriteBytes = _externalWriteBytes;
      if (externalWriteBytes != null) {
        return externalWriteBytes(utf8.encode(text));
      }
      return false;
    }
    process.stdin.add(utf8.encode(text));
    return true;
  }

  /// Writes already-encoded bytes directly to terminal stdin.
  @override
  bool writeBytes(List<int> bytes) {
    final session = _ptySession;
    if (session != null) {
      return session.writeBytes(Uint8List.fromList(bytes)) > 0;
    }

    final process = _process;
    if (process == null) {
      final externalWriteBytes = _externalWriteBytes;
      if (externalWriteBytes != null) {
        return externalWriteBytes(bytes);
      }
      return false;
    }
    process.stdin.add(bytes);
    return true;
  }

  /// Encodes and sends a key event using Ghostty's keyboard protocol rules.
  bool sendKey({
    required GhosttyKey key,
    GhosttyKeyAction action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS,
    int mods = 0,
    int consumedMods = 0,
    bool composing = false,
    String utf8Text = '',
    int unshiftedCodepoint = 0,
  }) {
    if (_process == null &&
        _ptySession == null &&
        _externalWriteBytes == null) {
      return false;
    }

    _encoder ??= VtKeyEncoder();
    final terminal = _terminal;
    if (terminal != null) {
      _encoder!.setOptionsFromTerminal(terminal);
    }

    final event = VtKeyEvent();
    try {
      event
        ..action = action
        ..key = key
        ..mods = mods
        ..consumedMods = consumedMods
        ..composing = composing
        ..utf8Text = utf8Text
        ..unshiftedCodepoint = unshiftedCodepoint;
      final encoded = _encoder!.encode(event);
      return writeBytes(encoded);
    } finally {
      event.close();
    }
  }

  /// Encodes and sends a mouse event using Ghostty's mouse protocol rules.
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
    if (_process == null &&
        _ptySession == null &&
        _externalWriteBytes == null) {
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

    final event = VtMouseEvent();
    try {
      event
        ..action = action
        ..button = button
        ..mods = mods
        ..position = position;
      final encoded = _mouseEncoder!.encode(event);
      return writeBytes(encoded);
    } finally {
      event.close();
    }
  }

  /// Injects decoded terminal output directly into the VT model.
  ///
  /// This is primarily intended for demos and tests that need to simulate
  /// process output without a live subprocess.
  void appendDebugOutput(String text) {
    _ingestBytes(utf8.encode(text));
  }

  void _onProcessBytes(List<int> bytes) {
    _ingestBytes(bytes);
  }

  /// Callback invoked by the VT engine when the terminal needs to send data
  /// back to the PTY (e.g. DSR responses, mode queries, DA replies).
  ///
  /// The [data] buffer is only valid for the duration of this call.
  void _onTerminalWritePty(Uint8List data) {
    final session = _ptySession;
    if (session != null) {
      session.writeBytes(Uint8List.fromList(data));
    } else {
      final process = _process;
      if (process != null) {
        process.stdin.add(data);
      } else {
        _externalWriteBytes?.call(Uint8List.fromList(data));
      }
    }

    onWritePtyData?.call(Uint8List.fromList(data));
  }

  void _ingestBytes(List<int> bytes) {
    if (bytes.isEmpty) {
      return;
    }

    _ensureTerminal().writeBytes(bytes);
    _refreshSnapshot();
    _markDirty();
  }

  void _refreshSnapshot() {
    final formatter = _plainFormatter;
    final styledFormatter = _styledFormatter;
    final renderState = _renderState;
    if (formatter == null || styledFormatter == null || renderState == null) {
      _plainText = '';
      _lines
        ..clear()
        ..add('');
      _snapshot = const GhosttyTerminalSnapshot.empty();
      _renderSnapshot = null;
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

    // Determine which rows are soft-wrapped by comparing a normal formatter
    // pass (where soft-wrapped lines still emit \n) against an unwrapped pass
    // (where soft-wrapped lines are joined and only hard newlines emit \n).
    // Any row index in [wrappedRows] has wrap: true; its successor has
    // wrapContinuation: true.
    //
    // The unwrapped text is computed here once and passed in so that
    // _computeWrappedRows does not need to call formatText() itself, keeping
    // _refreshSnapshot to exactly two formatter passes (plain + styled).
    final unwrappedText = _unwrapFormatter?.formatText();
    final wrappedRows = _computeWrappedRows(parts, unwrappedText);

    _snapshot = GhosttyTerminalSnapshot.fromFormattedVt(
      styledFormatter.formatText(),
      maxLines: maxLines,
      wrappedRows: wrappedRows,
    );
    renderState.update();
    _renderSnapshot = _toRenderSnapshot(renderState.snapshot());
  }

  /// Computes the set of zero-based row indices (within [wrappedLines]) that
  /// are soft-wrapped by comparing against the unwrapped formatter output.
  ///
  /// The plain formatter (with `unwrap: false`) emits a `\n` for every row
  /// boundary — both soft wraps and hard newlines.  With `unwrap: true` it
  /// omits the `\n` between soft-wrapped rows, joining them into a single
  /// logical line.  By walking both line lists in parallel we can infer which
  /// row boundaries in [wrappedLines] are soft wraps.
  ///
  /// [unwrappedText] must be the output of `_unwrapFormatter.formatText()`,
  /// pre-computed by the caller so no additional formatter pass is needed here.
  Set<int>? _computeWrappedRows(
    List<String> wrappedLines,
    String? unwrappedText,
  ) {
    if (unwrappedText == null) {
      return null;
    }

    final unwrappedLines = unwrappedText.isEmpty
        ? <String>['']
        : unwrappedText.split('\n');

    // If the counts match there are no soft-wrapped rows.
    if (wrappedLines.length == unwrappedLines.length) {
      return null;
    }

    // Walk both lists: each unwrapped logical line corresponds to one or more
    // consecutive wrapped rows.  Rows that are not the last in their logical
    // group are soft-wrapped.
    final result = <int>{};
    var wrappedIndex = 0;
    for (final logicalLine in unwrappedLines) {
      if (wrappedIndex >= wrappedLines.length) {
        break;
      }
      // Reconstruct the logical line from consecutive wrapped rows.
      final buffer = StringBuffer(wrappedLines[wrappedIndex]);
      while (wrappedIndex < wrappedLines.length - 1 &&
          buffer.toString() != logicalLine) {
        // This row is soft-wrapped — it joins the next.
        result.add(wrappedIndex);
        wrappedIndex++;
        buffer.write(wrappedLines[wrappedIndex]);
      }
      wrappedIndex++;
    }

    return result.isEmpty ? null : result;
  }

  void _markDirty() {
    _revision++;
    if (!_disposed) {
      notifyListeners();
    }
  }

  bool _canUsePtyBackend() {
    if (!preferPty) {
      return false;
    }
    return Platform.isLinux ||
        Platform.isMacOS ||
        Platform.isAndroid ||
        Platform.isIOS;
  }

  Future<Process> _spawnProcess(
    String shell,
    List<String> arguments, {
    Map<String, String>? environment,
  }) async {
    return Process.start(
      shell,
      arguments,
      runInShell: true,
      environment: environment,
    );
  }

  String _defaultShell() {
    return ghosttyTerminalDefaultShell(
      isWindows: Platform.isWindows,
      isAndroid: Platform.isAndroid,
      isIOS: Platform.isIOS,
      platformEnvironment: Platform.environment,
    );
  }

  GhosttyTerminalShellLaunch _freezeLaunch(GhosttyTerminalShellLaunch launch) {
    return GhosttyTerminalShellLaunch(
      label: launch.label,
      shell: launch.shell,
      arguments: List<String>.unmodifiable(launch.arguments),
      environment: launch.environment == null
          ? null
          : Map<String, String>.unmodifiable(launch.environment!),
      setupCommand: launch.setupCommand,
    );
  }

  String _shellLabel(String shell) {
    final parts = shell.split(RegExp(r'[\\/]'));
    return parts.isEmpty ? shell : parts.last;
  }

  Future<void> _disposeAsync() async {
    await stop();
    _encoder?.close();
    _encoder = null;
    _mouseEncoder?.close();
    _mouseEncoder = null;
    _renderState?.close();
    _renderState = null;
    _plainFormatter?.close();
    _plainFormatter = null;
    _styledFormatter?.close();
    _styledFormatter = null;
    _unwrapFormatter?.close();
    _unwrapFormatter = null;
    _terminal?.close();
    _terminal = null;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_disposeAsync());
    super.dispose();
  }
}

GhosttyTerminalRenderSnapshot _toRenderSnapshot(VtRenderSnapshot snapshot) {
  Color toColor(VtRgbColor color) =>
      Color.fromARGB(0xFF, color.r, color.g, color.b);

  final defaultForeground = toColor(snapshot.colors.foreground);
  final defaultBackground = toColor(snapshot.colors.background);
  final cursorColor = snapshot.colors.cursor == null
      ? null
      : toColor(snapshot.colors.cursor!);

  Color? resolveCellBackgroundColor(VtCellSnapshot rawCell) {
    if (rawCell.contentTag ==
        GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE) {
      final paletteIndex = rawCell.colorPaletteIndex;
      if (paletteIndex == null) {
        return null;
      }
      if (paletteIndex >= 0 && paletteIndex < snapshot.colors.palette.length) {
        return toColor(snapshot.colors.paletteAt(paletteIndex));
      }
      return GhosttyTerminalPalette.xterm.resolve(
        GhosttyTerminalColor.palette(paletteIndex),
        fallback: defaultBackground,
      );
    }
    if (rawCell.contentTag !=
            GhosttyCellContentTag.GHOSTTY_CELL_CONTENT_BG_COLOR_RGB ||
        rawCell.colorRgb == null) {
      return null;
    }
    return toColor(rawCell.colorRgb!);
  }

  final rows = snapshot.rowsData
      .map(
        (row) => GhosttyTerminalRenderRow(
          dirty: row.dirty,
          wrap: row.raw.wrap,
          wrapContinuation: row.raw.wrapContinuation,
          hasGrapheme: row.raw.hasGrapheme,
          styled: row.raw.styled,
          hasHyperlink: row.raw.hasHyperlink,
          semanticPrompt: row.raw.semanticPrompt,
          kittyVirtualPlaceholder: row.raw.kittyVirtualPlaceholder,
          cells: row.cells
              .where(
                (cell) =>
                    cell.raw.wide !=
                    GhosttyCellWide.GHOSTTY_CELL_WIDE_SPACER_TAIL,
              )
              .map(
                (cell) => GhosttyTerminalRenderCell(
                  text: cell.graphemes,
                  width: switch (cell.raw.wide) {
                    GhosttyCellWide.GHOSTTY_CELL_WIDE_WIDE => 2,
                    _ => 1,
                  },
                  hasText: cell.raw.hasText,
                  hasStyling: cell.raw.hasStyling,
                  hasHyperlink: cell.raw.hasHyperlink,
                  isProtected: cell.raw.isProtected,
                  semanticContent: cell.raw.semanticContent,
                  metadata: () {
                    final bgColor = resolveCellBackgroundColor(cell.raw);
                    return GhosttyTerminalRenderCellMetadata(
                      codepoint: cell.raw.codepoint,
                      contentTag: cell.raw.contentTag,
                      styleId: cell.raw.styleId,
                      colorPaletteIndex: cell.raw.colorPaletteIndex,
                      colorRgb: bgColor,
                      wide: cell.raw.wide,
                      hasBackgroundColor: bgColor != null,
                      backgroundColor: bgColor,
                    );
                  }(),
                  style:
                      GhosttyTerminalResolvedStyle.fromNativeStyleWithRenderColors(
                        style: cell.style,
                        colors: snapshot.colors,
                      ),
                ),
              )
              .toList(growable: false),
        ),
      )
      .toList(growable: false);

  return GhosttyTerminalRenderSnapshot(
    cols: snapshot.cols,
    rows: snapshot.rows,
    dirty: snapshot.dirty,
    backgroundColor: defaultBackground,
    foregroundColor: defaultForeground,
    cursor: GhosttyTerminalRenderCursor(
      visualStyle: snapshot.cursor.visualStyle,
      visible: snapshot.cursor.visible,
      blinking: snapshot.cursor.blinking,
      passwordInput: snapshot.cursor.passwordInput,
      hasViewportPosition: snapshot.cursor.hasViewportPosition,
      row: snapshot.cursor.viewportY,
      col: snapshot.cursor.viewportX,
      onWideTail: snapshot.cursor.onWideTail ?? false,
      color: cursorColor,
    ),
    rowsData: rows,
  );
}
