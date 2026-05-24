import 'dart:typed_data';

import 'package:ghostty_vte/ghostty_vte.dart';
import 'package:test/test.dart';

void main() {
  test('safe paste for plain text', () {
    expect(GhosttyVt.isPasteSafe('echo hello'), isTrue);
  });

  test('unsafe paste when newline is present', () {
    expect(GhosttyVt.isPasteSafe('echo hello\nrm -rf /'), isFalse);
  });

  test('build info exposes version metadata', () {
    final info = GhosttyVt.buildInfo;

    expect(info.versionString, isNotEmpty);
    expect(info.versionMajor, greaterThanOrEqualTo(0));
    expect(info.versionMinor, greaterThanOrEqualTo(0));
    expect(info.versionPatch, greaterThanOrEqualTo(0));
    expect(info.optimize, isIn(GhosttyOptimizeMode.values));
    expect(info.versionString, contains(info.versionCore));
  });

  test('paste encoder wraps bracketed paste', () {
    expect(
      GhosttyVt.encodePaste('hello', bracketed: true),
      '\x1b[200~hello\x1b[201~',
    );
  });

  test('paste encoder rewrites unsafe bytes for plain paste', () {
    final encoded = GhosttyVt.encodePasteBytes(<int>[
      0x61,
      0x1B,
      0x62,
      0x0A,
      0x63,
    ]);
    expect(encoded, <int>[0x61, 0x20, 0x62, 0x0D, 0x63]);
  });

  test('OSC parser parses window title command', () {
    final parser = VtOscParser();
    addTearDown(parser.close);

    parser.addText('0;ghostty');
    final command = parser.end();

    expect(
      command.type,
      GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE,
    );
    expect(command.windowTitle, 'ghostty');
    expect(command.isValid, isTrue);
    expect(command.isWindowTitleChange, isTrue);
    expect(command.isHyperlink, isFalse);
  });

  test('OSC parser returns INVALID for garbage input without crashing', () {
    final parser = VtOscParser();
    addTearDown(parser.close);

    // Feed ESC/control bytes that don't form a valid OSC payload —
    // this previously caused a segfault in ghostty_osc_command_data.
    parser.addByte(0x1B); // ESC
    parser.addByte(0x5D); // ]
    parser.addText('not-a-real-osc');

    final command = parser.end();

    expect(command.type, GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID);
    expect(command.windowTitle, isNull);
  });

  test('OSC parser returns INVALID when end() is called with no data', () {
    final parser = VtOscParser();
    addTearDown(parser.close);

    final command = parser.end();
    expect(command.type, GhosttyOscCommandType.GHOSTTY_OSC_COMMAND_INVALID);
    expect(command.isValid, isFalse);
  });

  test('SGR parser parses bold + red foreground', () {
    final parser = VtSgrParser();
    addTearDown(parser.close);

    final attrs = parser.parseParams(<int>[1, 31]);
    expect(
      attrs.any((a) => a.tag == GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BOLD),
      isTrue,
    );

    final color = attrs.firstWhere(
      (a) =>
          a.tag == GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_FG_8 ||
          a.tag == GhosttySgrAttributeTag.GHOSTTY_SGR_ATTR_BG_8,
    );
    expect(color.paletteIndex, GhosttyNamedColor.red);
  });

  test('key event setters/getters work', () {
    final event = VtKeyEvent();
    addTearDown(event.close);

    event
      ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
      ..key = GhosttyKey.GHOSTTY_KEY_A
      ..mods = GhosttyModsMask.shift | GhosttyModsMask.ctrl
      ..consumedMods = GhosttyModsMask.shift
      ..composing = true
      ..utf8Text = 'A'
      ..unshiftedCodepoint = 0x61;

    expect(event.action, GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS);
    expect(event.key, GhosttyKey.GHOSTTY_KEY_A);
    expect(event.mods, GhosttyModsMask.shift | GhosttyModsMask.ctrl);
    expect(event.consumedMods, GhosttyModsMask.shift);
    expect(event.composing, isTrue);
    expect(event.utf8Text, 'A');
    expect(event.unshiftedCodepoint, 0x61);
  });

  test('key encoder produces bytes for Ctrl+C', () {
    final encoder = VtKeyEncoder();
    final event = VtKeyEvent();
    addTearDown(encoder.close);
    addTearDown(event.close);

    encoder.kittyFlags = GhosttyKittyFlags.all;
    event
      ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
      ..key = GhosttyKey.GHOSTTY_KEY_C
      ..mods = GhosttyModsMask.ctrl
      ..utf8Text = 'c'
      ..unshiftedCodepoint = 0x63;

    final encoded = encoder.encode(event);
    expect(encoded, isNotEmpty);
  });

  test('key encoder options apply a reusable Kitty profile', () {
    final encoder = VtKeyEncoder();
    final event = VtKeyEvent();
    addTearDown(encoder.close);
    addTearDown(event.close);

    const VtKeyEncoderOptions.kitty(
      kittyFlags: GhosttyKittyFlags.disambiguate,
      altEscPrefix: true,
      modifyOtherKeysState2: true,
    ).applyTo(encoder);
    event
      ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
      ..key = GhosttyKey.GHOSTTY_KEY_A
      ..mods = GhosttyModsMask.alt
      ..utf8Text = 'a'
      ..unshiftedCodepoint = 0x61;

    expect(encoder.encode(event), isNotEmpty);
  });

  test('key encoder emits DEL for plain backspace', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    final encoder = VtKeyEncoder();
    final event = VtKeyEvent();
    addTearDown(terminal.close);
    addTearDown(encoder.close);
    addTearDown(event.close);

    encoder.setOptionsFromTerminal(terminal);
    event
      ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
      ..key = GhosttyKey.GHOSTTY_KEY_BACKSPACE
      ..mods = 0
      ..consumedMods = 0
      ..composing = false
      ..utf8Text = ''
      ..unshiftedCodepoint = 0;

    expect(encoder.encode(event), [0x7F]);
  });

  test('focus encoder emits CSI I and CSI O', () {
    expect(
      String.fromCharCodes(
        GhosttyVt.encodeFocus(GhosttyFocusEvent.GHOSTTY_FOCUS_GAINED),
      ),
      '\x1b[I',
    );
    expect(
      String.fromCharCodes(
        GhosttyVt.encodeFocus(GhosttyFocusEvent.GHOSTTY_FOCUS_LOST),
      ),
      '\x1b[O',
    );
  });

  test('mode report encoder emits DEC private mode report', () {
    expect(
      String.fromCharCodes(
        GhosttyVt.encodeModeReport(
          const VtMode(1),
          GhosttyModeReportState.GHOSTTY_MODE_REPORT_SET,
        ),
      ),
      '\x1b[?1;1\$y',
    );
  });

  test('size report encoder emits CSI 18 t report', () {
    expect(
      String.fromCharCodes(
        GhosttyVt.encodeSizeReport(
          GhosttySizeReportStyle.GHOSTTY_SIZE_REPORT_CSI_18_T,
          const VtSizeReportSize(
            rows: 24,
            columns: 80,
            cellWidth: 8,
            cellHeight: 16,
          ),
        ),
      ),
      '\x1b[8;24;80t',
    );
  });

  test('terminal formatter outputs plain text', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('Hello');

    expect(formatter.formatText(), 'Hello');
  });

  test('terminal color wrappers expose effective and default colors', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal
      ..defaultForegroundColor = const VtRgbColor(0x11, 0x22, 0x33)
      ..defaultBackgroundColor = const VtRgbColor(0x44, 0x55, 0x66)
      ..defaultCursorColor = const VtRgbColor(0x77, 0x88, 0x99)
      ..defaultPalette = List<VtRgbColor>.generate(
        256,
        (index) => VtRgbColor(index, index, 255 - index),
      );

    final effective = terminal.effectiveColors;
    final defaults = terminal.defaultColors;

    expect(effective.foreground?.r, 0x11);
    expect(effective.background?.g, 0x55);
    expect(effective.cursor?.b, 0x99);
    expect(effective.paletteAt(7).g, 7);
    expect(effective.paletteAt(7).b, 248);

    expect(defaults.foreground?.r, 0x11);
    expect(defaults.background?.g, 0x55);
    expect(defaults.cursor?.b, 0x99);
    expect(defaults.paletteAt(42).r, 42);

    terminal.defaultForegroundColor = null;
    terminal.defaultBackgroundColor = null;
    terminal.defaultCursorColor = null;
    terminal.defaultPalette = null;

    expect(terminal.defaultForegroundColor, isNull);
    expect(terminal.defaultBackgroundColor, isNull);
    expect(terminal.defaultCursorColor, isNull);
    expect(terminal.defaultPalette, hasLength(256));
  });

  test('terminal formatter reflects terminal changes', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('Hello');
    expect(formatter.formatText(), 'Hello');

    terminal.write('\r\nWorld');
    expect(formatter.formatText(), 'Hello\nWorld');
  });

  test('terminal formatter allocation helper matches buffer helper', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('Hello\r\nWorld');

    expect(formatter.formatTextAllocated(), formatter.formatText());
    expect(formatter.formatBytesAllocated(), formatter.formatBytes());
  });

  test('terminal formatter allocation helper accepts explicit allocator', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('Hello\r\nWorld');

    expect(
      formatter.formatTextAllocatedWith(VtAllocator.dartMalloc),
      formatter.formatText(),
    );
    expect(
      formatter.formatBytesAllocatedWith(VtAllocator.dartMalloc),
      formatter.formatBytes(),
    );
  });

  test('terminal formatter can emit VT output', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        extra: VtFormatterTerminalExtra(
          screen: VtFormatterScreenExtra(style: true),
        ),
      ),
    );
    addTearDown(formatter.close);

    terminal.write('Hello\r\n\x1b[31mWorld\x1b[0m');

    final output = formatter.formatText();
    expect(output, contains('Hello'));
    expect(output, contains('World'));
    expect(output, contains('\x1b['));
  });

  test('terminal formatter all-extra preset emits rich state', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
        trim: false,
        extra: VtFormatterTerminalExtra.all(),
      ),
    );
    addTearDown(formatter.close);

    terminal.write('\x1b]0;ghostty\x07');
    terminal.write('\x1b[31mHello\x1b[0m');

    final output = formatter.formatText();
    expect(output, contains('Hello'));
    expect(output, contains('\x1b['));
  });

  test('terminal formatter can emit HTML output', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter(
      const VtFormatterTerminalOptions(
        emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_HTML,
      ),
    );
    addTearDown(formatter.close);

    terminal.write('Html');

    final output = formatter.formatText();
    expect(output.toLowerCase(), contains('html'));
    expect(output.toLowerCase(), contains('<div'));
  });

  test('terminal resize updates tracked dimensions', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal.resize(cols: 40, rows: 12);

    expect(terminal.cols, 40);
    expect(terminal.rows, 12);
    expect(terminal.cursorPosition.x, 0);
    expect(terminal.cursorPosition.y, 0);
    expect(terminal.isPrimaryScreen, isTrue);
    expect(terminal.isAlternateScreen, isFalse);
  });

  test('terminal mode getters and setters expose native mode state', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.getMode(VtModes.cursorKeys), isFalse);
    terminal.setMode(VtModes.cursorKeys, true);
    expect(terminal.getMode(VtModes.cursorKeys), isTrue);
    terminal.setMode(VtModes.cursorKeys, false);
    expect(terminal.getMode(VtModes.cursorKeys), isFalse);
  });

  test('terminal mouse protocol state aggregates mode flags', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.mouseProtocolState.enabled, isFalse);
    expect(terminal.mouseProtocolState.trackingMode, isNull);
    expect(terminal.mouseProtocolState.format, isNull);

    terminal.setMode(VtModes.normalMouse, true);
    terminal.setMode(VtModes.sgrMouse, true);
    terminal.setMode(VtModes.focusEvent, true);

    final state = terminal.mouseProtocolState;
    expect(state.enabled, isTrue);
    expect(state.trackingMode?.value, 2);
    expect(state.format?.value, 2);
    expect(state.focusEvents, isTrue);
    expect(state.altScroll, terminal.getMode(VtModes.altScroll));
  });

  test('terminal reset clears formatter output', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('Hello');
    expect(formatter.formatText(), 'Hello');

    terminal.reset();
    expect(formatter.formatText(), '');
  });

  test('terminal grid ref exposes cell, row, style, and graphemes', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    addTearDown(terminal.close);

    terminal.write('A');

    final ref = terminal.gridRef(const VtPoint.active(0, 0));
    expect(ref.graphemes, 'A');
    expect(ref.cell.codepoint, 'A'.codeUnitAt(0));
    expect(ref.cell.hasText, isTrue);
    expect(ref.row.wrap, isFalse);
  });

  test('terminal convenience cell lookups map to grid refs', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    addTearDown(terminal.close);

    terminal.write('A');

    expect(terminal.activeCell(0, 0).graphemes, 'A');
    expect(terminal.viewportCell(0, 0).graphemes, 'A');
    expect(terminal.screenCell(0, 0).graphemes, 'A');
  });

  test('render state snapshots visible rows and cells', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    final renderState = terminal.createRenderState();
    addTearDown(renderState.close);
    addTearDown(terminal.close);

    terminal.write('A\x1b[31mB\x1b[0m');
    renderState.update();
    final snapshot = renderState.snapshot();

    expect(snapshot.cols, 8);
    expect(snapshot.rows, 4);
    expect(snapshot.rowsData, isNotEmpty);
    expect(snapshot.rowsData.first.cells[0].graphemes, 'A');
    expect(snapshot.rowsData.first.cells[1].graphemes, 'B');
    expect(snapshot.rowsData.first.cells[1].style.foreground.isSet, isTrue);
    expect(snapshot.cellAt(row: 0, column: 1).graphemes, 'B');
    expect(
      snapshot.colors.resolveForeground(
        snapshot.cellAt(row: 0, column: 1).style,
      ),
      isNotNull,
    );
    expect(
      snapshot.cursor.isBlock ||
          snapshot.cursor.isBar ||
          snapshot.cursor.isUnderline,
      isTrue,
    );
  });

  test('render state exposes mutable dirty flag and live row cursors', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    final renderState = terminal.createRenderState();
    addTearDown(renderState.close);
    addTearDown(terminal.close);

    terminal.write('AB\r\nCD');
    renderState.update();

    expect(renderState.dirty, isNotNull);
    renderState.dirty =
        GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
    expect(
      renderState.dirty,
      GhosttyRenderStateDirty.GHOSTTY_RENDER_STATE_DIRTY_FALSE,
    );

    var visitedRows = 0;
    VtRenderCellSnapshot? selectedCell;
    renderState.visitRows((row) {
      visitedRows += 1;
      if (visitedRows == 1) {
        row.dirty = false;
        expect(row.dirty, isFalse);

        row.visitCells((cells) {
          selectedCell = cells.cellAt(1);
        });
      }
    });

    expect(visitedRows, greaterThan(0));
    expect(selectedCell?.graphemes, 'B');
  });

  test('render state exposes live viewport and cursor getters', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    final renderState = terminal.createRenderState();
    addTearDown(renderState.close);
    addTearDown(terminal.close);

    terminal.write('AB');
    renderState.update();

    expect(renderState.cols, 8);
    expect(renderState.rows, 4);
    expect(renderState.colors.palette, hasLength(256));
    expect(renderState.colors.foreground, isA<VtRgbColor>());
    expect(renderState.colors.background, isA<VtRgbColor>());

    final cursor = renderState.cursorSnapshot;
    expect(cursor.visualStyle, renderState.cursorVisualStyle);
    expect(cursor.visible, renderState.cursorVisible);
    expect(cursor.blinking, renderState.cursorBlinking);
    expect(cursor.passwordInput, renderState.cursorPasswordInput);
    expect(cursor.hasViewportPosition, renderState.cursorHasViewportPosition);
    expect(cursor.viewportX, renderState.cursorViewportX);
    expect(cursor.viewportY, renderState.cursorViewportY);
    expect(cursor.onWideTail, renderState.cursorOnWideTail);
  });

  test('style default helpers round-trip to native defaults', () {
    final style = VtStyle.defaults();

    expect(style.isDefault, isTrue);
    expect(style.foreground.isSet, isFalse);
    expect(style.background.isSet, isFalse);
    expect(style.underlineColor.isSet, isFalse);
  });

  test('cell and row convenience helpers expose structural metadata', () {
    final terminal = GhosttyVt.newTerminal(cols: 8, rows: 4);
    addTearDown(terminal.close);

    terminal.write('A好');

    final asciiCell = terminal.activeCell(0, 0);
    final wideLeadCell = terminal.activeCell(1, 0);
    final wideTailCell = terminal.activeCell(2, 0);

    expect(asciiCell.cell.isEmpty, isFalse);
    expect(asciiCell.cell.isWideLead, isFalse);
    expect(wideLeadCell.cell.isWideLead, isTrue);
    expect(wideTailCell.cell.isWideTail, isTrue);
    expect(asciiCell.row.hasSemanticPrompt, isFalse);
    expect(asciiCell.cell.isPromptText, isFalse);
    expect(asciiCell.cell.isPromptInput, isFalse);
    expect(asciiCell.cell.isPromptOutput, isTrue);
  });

  test('mouse encoder emits SGR mouse sequences', () {
    final encoder = GhosttyVt.newMouseEncoder();
    final event = GhosttyVt.newMouseEvent();
    addTearDown(encoder.close);
    addTearDown(event.close);

    encoder
      ..trackingMode = GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_NORMAL
      ..format = GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR
      ..size = const VtMouseEncoderSize(
        screenWidth: 800,
        screenHeight: 600,
        cellWidth: 10,
        cellHeight: 20,
      );

    event
      ..action = GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS
      ..button = GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT
      ..position = const VtMousePosition(x: 15, y: 25);

    expect(String.fromCharCodes(encoder.encode(event)), '\x1b[<0;2;2M');
  });

  test('mouse encoder options apply reusable SGR profile', () {
    final encoder = GhosttyVt.newMouseEncoder();
    final event = GhosttyVt.newMouseEvent();
    addTearDown(encoder.close);
    addTearDown(event.close);

    const VtMouseEncoderOptions.sgr(
      size: VtMouseEncoderSize(
        screenWidth: 800,
        screenHeight: 600,
        cellWidth: 10,
        cellHeight: 20,
      ),
    ).applyTo(encoder);

    event
      ..action = GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS
      ..button = GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT
      ..position = const VtMousePosition(x: 15, y: 25);

    expect(String.fromCharCodes(encoder.encode(event)), '\x1b[<0;2;2M');
  });

  test('terminal scroll viewport APIs are callable', () {
    final terminal = GhosttyVt.newTerminal(cols: 5, rows: 2);
    addTearDown(terminal.close);
    final formatter = terminal.createFormatter();
    addTearDown(formatter.close);

    terminal.write('hello');
    terminal.write('\x1bD\x1bD\x1bD');

    expect(() => terminal.scrollToTop(), returnsNormally);
    expect(() => terminal.scrollToBottom(), returnsNormally);
    expect(() => terminal.scrollBy(-3), returnsNormally);
    expect(formatter.formatText(), 'hello');
  });

  test('key encoder can mirror terminal cursor key mode', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    final encoder = GhosttyVt.newKeyEncoder();
    final event = GhosttyVt.newKeyEvent();
    addTearDown(terminal.close);
    addTearDown(encoder.close);
    addTearDown(event.close);

    terminal.setMode(VtModes.cursorKeys, true);
    encoder.setOptionsFromTerminal(terminal);

    event
      ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
      ..key = GhosttyKey.GHOSTTY_KEY_ARROW_UP;

    expect(String.fromCharCodes(encoder.encode(event)), '\x1bOA');
  });

  test('closing terminal invalidates borrowed formatter', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    final formatter = terminal.createFormatter();

    terminal.close();

    expect(formatter.formatText, throwsStateError);
  });

  test('terminal resize accepts pixel dimensions', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal.resize(cols: 40, rows: 12, cellWidthPx: 8, cellHeightPx: 16);

    expect(terminal.cols, 40);
    expect(terminal.rows, 12);
  });

  test('onWritePty receives data when terminal produces a DSR response', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);

    // Device Status Report query: CSI 5 n
    // Expected response: CSI 0 n (terminal OK)
    terminal.write('\x1b[5n');

    expect(received, isNotEmpty);
    expect(String.fromCharCodes(received.first), '\x1b[0n');
  });

  test('onWritePty can be cleared by setting to null', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onWritePty = null;

    // This DSR query should be silently ignored now.
    terminal.write('\x1b[5n');

    expect(received, isEmpty);
  });

  test('onWritePty is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    var callCount = 0;
    terminal.onWritePty = (_) => callCount++;

    terminal.close();

    // After close, the callback should be null.
    expect(terminal.onWritePty, isNull);
  });

  // --- onBell callback tests ---

  test('onBell fires when terminal receives BEL character', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var bellCount = 0;
    terminal.onBell = () => bellCount++;

    terminal.write('\x07');

    expect(bellCount, 1);
  });

  test('onBell can be cleared by setting to null', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var bellCount = 0;
    terminal.onBell = () => bellCount++;
    terminal.onBell = null;

    terminal.write('\x07');

    expect(bellCount, 0);
  });

  test('onBell is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onBell = () {};
    terminal.close();

    expect(terminal.onBell, isNull);
  });

  // --- onTitleChanged callback tests ---

  test('onTitleChanged fires on OSC 2 title change', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var titleChangedCount = 0;
    terminal.onTitleChanged = () => titleChangedCount++;

    // OSC 2 ; <title> ST — set window title
    terminal.write('\x1b]2;hello world\x07');

    expect(titleChangedCount, 1);
  });

  test('onTitleChanged can be cleared by setting to null', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var titleChangedCount = 0;
    terminal.onTitleChanged = () => titleChangedCount++;
    terminal.onTitleChanged = null;

    terminal.write('\x1b]2;hello\x07');

    expect(titleChangedCount, 0);
  });

  test('onTitleChanged is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onTitleChanged = () {};
    terminal.close();

    expect(terminal.onTitleChanged, isNull);
  });

  // --- onSizeQuery callback tests ---

  test('onSizeQuery fires on XTWINOPS size query and sends response', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var sizeQueryCount = 0;
    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onSizeQuery = () {
      sizeQueryCount++;
      return VtSizeReportSize(
        rows: 24,
        columns: 80,
        cellWidth: 8,
        cellHeight: 16,
      );
    };

    // CSI 18 t — report the size of the text area in characters
    terminal.write('\x1b[18t');

    expect(sizeQueryCount, 1);
    // The terminal should have produced a response via onWritePty.
    expect(received, isNotEmpty);
  });

  test('onSizeQuery returns null to silently ignore', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onSizeQuery = () => null;

    terminal.write('\x1b[18t');

    // No response should be sent when callback returns null.
    expect(received, isEmpty);
  });

  test('onSizeQuery is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onSizeQuery = () => null;
    terminal.close();

    expect(terminal.onSizeQuery, isNull);
  });

  // --- onColorSchemeQuery callback tests ---

  test('onColorSchemeQuery fires on CSI ? 996 n', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var queryCount = 0;
    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onColorSchemeQuery = () {
      queryCount++;
      return GhosttyColorScheme.GHOSTTY_COLOR_SCHEME_DARK;
    };

    // CSI ? 996 n — color scheme query
    terminal.write('\x1b[?996n');

    expect(queryCount, 1);
    expect(received, isNotEmpty);
  });

  test('onColorSchemeQuery is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onColorSchemeQuery = () =>
        GhosttyColorScheme.GHOSTTY_COLOR_SCHEME_DARK;
    terminal.close();

    expect(terminal.onColorSchemeQuery, isNull);
  });

  // --- onDeviceAttributesQuery callback tests ---

  test('onDeviceAttributesQuery fires on DA1 query', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var queryCount = 0;
    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onDeviceAttributesQuery = () {
      queryCount++;
      return VtDeviceAttributes(
        primary: VtDeviceAttributesPrimary(
          conformanceLevel: 62,
          features: [1, 6, 7, 22],
        ),
        secondary: VtDeviceAttributesSecondary(
          deviceType: 1,
          firmwareVersion: 10,
        ),
        tertiary: VtDeviceAttributesTertiary(unitId: 0),
      );
    };

    // CSI c — DA1 query
    terminal.write('\x1b[c');

    expect(queryCount, 1);
    expect(received, isNotEmpty);
  });

  test('onDeviceAttributesQuery is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onDeviceAttributesQuery = () => null;
    terminal.close();

    expect(terminal.onDeviceAttributesQuery, isNull);
  });

  // --- onEnquiry callback tests ---

  test('onEnquiry fires on ENQ character and sends response', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var enquiryCount = 0;
    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onEnquiry = () {
      enquiryCount++;
      return Uint8List.fromList([0x4F, 0x4B]); // "OK"
    };

    // ENQ character (0x05)
    terminal.write('\x05');

    expect(enquiryCount, 1);
    expect(received, isNotEmpty);
    expect(String.fromCharCodes(received.first), 'OK');
  });

  test('onEnquiry returning empty list sends no response', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onEnquiry = () => Uint8List(0);

    terminal.write('\x05');

    // Empty response should not produce any PTY output.
    expect(received, isEmpty);
  });

  test('onEnquiry is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onEnquiry = () => Uint8List(0);
    terminal.close();

    expect(terminal.onEnquiry, isNull);
  });

  // --- onXtversion callback tests ---

  test('onXtversion fires on CSI > q and sends response', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    var xtversionCount = 0;
    final received = <List<int>>[];
    terminal.onWritePty = (data) => received.add(data);
    terminal.onXtversion = () {
      xtversionCount++;
      return 'myterm 1.0';
    };

    // CSI > q — XTVERSION query
    terminal.write('\x1b[>q');

    expect(xtversionCount, 1);
    expect(received, isNotEmpty);
  });

  test(
    'onXtversion returning empty string sends default libghostty version',
    () {
      final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
      addTearDown(terminal.close);

      final received = <List<int>>[];
      terminal.onWritePty = (data) => received.add(data);
      terminal.onXtversion = () => '';

      terminal.write('\x1b[>q');

      // An empty string tells the terminal to report its built-in default
      // version (e.g. "libghostty"), so a response IS expected.
      expect(received, isNotEmpty);
      final response = String.fromCharCodes(received.first);
      expect(response, contains('libghostty'));
    },
  );

  test('onXtversion is cleaned up on close', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);

    terminal.onXtversion = () => 'test';
    terminal.close();

    expect(terminal.onXtversion, isNull);
  });

  // --- title and pwd getter tests ---

  test('title returns empty string when no title has been set', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.title, isEmpty);
  });

  test('title returns the value set by OSC 2', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal.write('\x1b]2;hello world\x07');

    expect(terminal.title, 'hello world');
  });

  test('title updates when changed by a second OSC 2', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal.write('\x1b]2;first\x07');
    expect(terminal.title, 'first');

    terminal.write('\x1b]2;second\x07');
    expect(terminal.title, 'second');
  });

  test('pwd returns empty string when no pwd has been set', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.pwd, isEmpty);
  });

  // --- mouseTracking, totalRows, scrollbackRows, widthPx, heightPx ---

  test('mouseTracking is false by default', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.mouseTracking, isFalse);
  });

  test('mouseTracking becomes true when a mouse mode is enabled', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    // Enable X10 mouse tracking (mode 9)
    terminal.write('\x1b[?9h');
    expect(terminal.mouseTracking, isTrue);
  });

  test('totalRows equals rows for a fresh terminal', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.totalRows, 24);
  });

  test('scrollbackRows is zero for a fresh terminal', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    expect(terminal.scrollbackRows, 0);
  });

  test('widthPx and heightPx reflect pixel dimensions from resize', () {
    final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
    addTearDown(terminal.close);

    terminal.resize(cols: 80, rows: 24, cellWidthPx: 10, cellHeightPx: 20);

    expect(terminal.widthPx, 80 * 10);
    expect(terminal.heightPx, 24 * 20);
  });
}
