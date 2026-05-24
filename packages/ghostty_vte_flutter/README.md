# ghostty_vte_flutter

[![CI](https://github.com/kingwill101/dart_terminal/actions/workflows/vte.yml/badge.svg)](https://github.com/kingwill101/dart_terminal/actions/workflows/vte.yml)
[![pub package](https://img.shields.io/pub/v/ghostty_vte_flutter.svg)](https://pub.dev/packages/ghostty_vte_flutter)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/kingwill101/dart_terminal/blob/master/pkgs/vte/ghostty_vte_flutter/LICENSE)

Flutter terminal UI widgets powered by
[Ghostty](https://github.com/ghostty-org/ghostty)'s VT engine.
Drop-in `GhosttyTerminalView` and `GhosttyTerminalController` for embedding
a terminal in any Flutter app — on desktop, mobile, and the web.

## Features

| Widget / Class | Description |
|----------------|-------------|
| `GhosttyTerminalView` | `CustomPaint`-based terminal renderer with keyboard input, text selection, hyperlink detection, and mouse reporting |
| `GhosttyTerminalController` | `ChangeNotifier` that manages a shell subprocess (native PTY or `Process`) or remote transport (web) |
| `GhosttyTerminalSnapshot` | Parsed styled terminal output with selection, word-boundary, and hyperlink support |
| `GhosttyTerminalRenderSnapshot` | High-fidelity cell-level render data from Ghostty's native render-state API |
| `initializeGhosttyVteWeb()` | One-liner that loads `ghostty-vt.wasm` from Flutter assets on web |

This package re-exports all of
[`ghostty_vte`](https://pub.dev/packages/ghostty_vte), so you only need a
single import.

### Platform support

| Platform | Native shell | Web (wasm) |
|----------|:------------:|:----------:|
| Linux    |      yes     |    yes     |
| macOS    |      yes     |    yes     |
| Windows  |      yes     |    yes     |
| Android  |      yes     |    yes     |
| iOS      |      yes     |    yes     |

## Installation

```yaml
dependencies:
  ghostty_vte_flutter: ^0.1.3
```

No separate `ghostty_vte` dependency is needed — it's re-exported
automatically.

## Quick start

A minimal terminal app with a live shell session:

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeGhosttyVteWeb(); // no-op on native, loads wasm on web
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) => const MaterialApp(home: TerminalPage());
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final _ctrl = GhosttyTerminalController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTerminal();
  }

  Future<void> _startTerminal() async {
    try {
      if (kIsWeb) {
        await _ctrl.start();
        _ctrl.appendDebugOutput(
          '\x1b]2;Ghostty VT Demo\x07'
          '\x1b[32mweb demo backend attached\x1b[0m\r\n'
          'Connect a backend and feed bytes with appendDebugOutput().\r\n',
        );
        return;
      }

      final launch = await _ctrl.startShellProfile(
        profile: GhosttyTerminalShellProfile.auto,
        platformEnvironment: ghosttyTerminalPlatformEnvironment(),
      );
      if (launch == null) {
        await _ctrl.start(
          environment: ghosttyTerminalShellEnvironment(
            platformEnvironment: ghosttyTerminalPlatformEnvironment(),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terminal')),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            ),
          Expanded(
            child: ColoredBox(
              color: Colors.black,
              child: GhosttyTerminalView(controller: _ctrl, autofocus: true),
            ),
          ),
        ],
      ),
    );
  }
}
```

On native platforms this starts a real shell session. On web it starts the VT
engine and shows a demo banner until you connect your own backend and stream
bytes into `appendDebugOutput()`.

## Controller

### Creating a controller

```dart
final controller = GhosttyTerminalController(
  maxLines: 2000,          // max retained lines in formatted snapshot
  maxScrollback: 10000,    // scrollback depth in the VT terminal
  initialCols: 80,         // initial grid width before layout
  initialRows: 24,         // initial grid height before layout
  preferPty: true,         // prefer native PTY over Process.start
  defaultShell: '/bin/bash',
);
```

### Starting a shell

```dart
// Simple start with defaults
await controller.start();

// Custom shell, arguments, and environment
await controller.start(
  shell: '/bin/zsh',
  arguments: ['-l'],
  environment: {'TERM': 'xterm-256color', 'LANG': 'en_US.UTF-8'},
);
```

### Shell profiles

Use the built-in shell profile resolver for common configurations:

```dart
final launch = await controller.startShellProfile(
  profile: GhosttyTerminalShellProfile.cleanBash,
  platformEnvironment: ghosttyTerminalPlatformEnvironment(),
  environmentOverrides: const {'TERM': 'xterm-256color'},
);

print(controller.activeShellLaunch?.commandLine);
print(controller.activeShellLaunch?.environment?['TERM']);
```

Available profiles: `auto`, `cleanBash`, `cleanZsh`, `userShell`.

### Shell environment helper

Build a usable native shell environment with sane defaults:

```dart
await controller.start(
  environment: ghosttyTerminalShellEnvironment(
    platformEnvironment: ghosttyTerminalPlatformEnvironment(),
    overrides: const {'TERM': 'xterm-256color'},
  ),
);
```

`ghosttyTerminalShellEnvironment()` preserves the caller's base
environment, sets `TERM`, fills `HOME`-derived `XDG_*` paths, and ensures a
UTF-8 locale when the input environment omitted one.

### Launch plans

For full control, create and start a resolved launch plan:

```dart
final launch = GhosttyTerminalShellLaunch(
  label: 'dev-shell',
  shell: '/bin/bash',
  arguments: ['--rcfile', '/path/to/custom.bashrc'],
  environment: {'TERM': 'xterm-256color'},
  setupCommand: 'cd ~/projects\n',
);

await controller.startLaunch(launch);

// Restart with the same launch plan
await controller.restartLaunch(launch);
```

### Writing input

```dart
// Write text to stdin (with optional paste safety check)
controller.write('ls -la\n');
controller.write('rm -rf /\n', sanitizePaste: true);  // rejected: unsafe

// Write raw bytes
controller.writeBytes(utf8.encode('hello'));
```

### Sending key events

```dart
// Send Ctrl+C
controller.sendKey(
  key: GhosttyKey.GHOSTTY_KEY_C,
  mods: GhosttyModsMask.ctrl,
  utf8Text: 'c',
  unshiftedCodepoint: 0x63,
);

// Send Enter
controller.sendKey(
  key: GhosttyKey.GHOSTTY_KEY_ENTER,
  utf8Text: '\r',
);

// Send arrow keys
controller.sendKey(key: GhosttyKey.GHOSTTY_KEY_ARROW_UP);
```

### Sending mouse events

```dart
controller.sendMouse(
  action: GhosttyMouseAction.GHOSTTY_MOUSE_ACTION_PRESS,
  button: GhosttyMouseButton.GHOSTTY_MOUSE_BUTTON_LEFT,
  position: VtMousePosition(col: 10, row: 5),
  size: VtMouseEncoderSize(cols: controller.cols, rows: controller.rows),
);
```

### Reading terminal state

```dart
print(controller.title);       // window title from OSC 0/2
print(controller.isRunning);   // subprocess alive?
print(controller.lines);       // buffered output lines
print(controller.lineCount);   // number of buffered lines
print(controller.plainText);   // full plain-text snapshot
print(controller.cols);        // current grid width
print(controller.rows);        // current grid height
print(controller.revision);    // monotonic change counter
```

### Styled snapshot

The controller exposes a `GhosttyTerminalSnapshot` parsed from VT
formatter output. This contains styled lines with full SGR attributes,
hyperlink detection, and selection support:

```dart
final snapshot = controller.snapshot;
for (final line in snapshot.lines) {
  for (final run in line.runs) {
    print('${run.text} bold=${run.style.bold} fg=${run.style.foreground}');
  }
}

// Text selection
final selection = GhosttyTerminalSelection(
  base: GhosttyTerminalCellPosition(row: 0, col: 0),
  extent: GhosttyTerminalCellPosition(row: 2, col: 10),
);
final selectedText = snapshot.textForSelection(selection);

// Word selection at a cell position
final wordSel = snapshot.wordSelectionAt(
  GhosttyTerminalCellPosition(row: 1, col: 5),
);

// Hyperlink detection
final link = snapshot.hyperlinkAt(
  GhosttyTerminalCellPosition(row: 3, col: 12),
);
```

### Native render-state snapshot

On native platforms, the controller also exposes a high-fidelity
`GhosttyTerminalRenderSnapshot` derived from Ghostty's incremental
render-state API:

```dart
final renderSnap = controller.renderSnapshot;
if (renderSnap != null) {
  print(renderSnap.cols);             // viewport width
  print(renderSnap.rows);             // viewport height
  print(renderSnap.dirty);            // dirty state
  print(renderSnap.cursor.visible);   // cursor visibility
  print(renderSnap.cursor.row);       // cursor row

  for (final row in renderSnap.rowsData) {
    for (final cell in row.cells) {
      // cell.text, cell.style.foreground, cell.style.bold, etc.
    }
  }
}
```

### Direct VT terminal access

The controller exposes the underlying `VtTerminal` for advanced use cases:

```dart
final terminal = controller.terminal;
print(terminal.cursorPosition);
print(terminal.isPrimaryScreen);
print(terminal.mouseProtocolState.enabled);

// Query terminal modes
final bracketedPaste = terminal.getMode(VtModes.bracketedPaste);

// Grid introspection
final cell = terminal.activeCell(0, 0);
print(cell.graphemeText);
print(cell.style);
```

### Custom formatted output

Generate terminal output in different formats on demand:

```dart
// Plain text with trimming
final plain = controller.formatTerminal();

// VT sequences with styles and cursor
final vt = controller.formatTerminal(
  emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
  trim: false,
  extra: const VtFormatterTerminalExtra.all(),
);
```

### Stopping and cleanup

```dart
await controller.stop();  // kill subprocess
controller.clear();       // reset terminal, clear scrollback
controller.dispose();     // release all resources
```

## View

### GhosttyTerminalView

A `CustomPaint` widget that renders terminal output, handles keyboard
events through the Ghostty key encoder, and supports text selection,
hyperlinks, and mouse reporting.

```dart
GhosttyTerminalView(
  controller: myController,
  autofocus: true,
  backgroundColor: const Color(0xFF0A0F14),
  foregroundColor: const Color(0xFFE6EDF3),
  fontSize: 14,
  lineHeight: 1.35,
  fontFamily: 'Noto Sans Mono',
  fontFamilyFallback: const ['Noto Sans Symbols 2'],
  cellWidthScale: 1.0,
  padding: const EdgeInsets.all(12),
  palette: GhosttyTerminalPalette.xterm,
  cursorColor: const Color(0xFF9AD1C0),
  selectionColor: const Color(0x665DA9FF),
  hyperlinkColor: const Color(0xFF61AFEF),
  renderer: GhosttyTerminalRendererMode.formatter,
  interactionPolicy: GhosttyTerminalInteractionPolicy.auto,
  touchDragBehavior: GhosttyTerminalTouchDragBehavior.scroll,
  showSelectionContextMenu: true,
  selectionContextMenuButtonItemsBuilder: (details) {
    return details.defaultButtonItems;
  },
  onSelectionChanged: (selection) { /* ... */ },
  onCopySelection: (text) { /* ... */ },
  onPasteRequest: () async => clipboardText,
  onOpenHyperlink: (uri) { /* ... */ },
)
```

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `controller` | `GhosttyTerminalController` | *required* | Terminal session to render |
| `autofocus` | `bool` | `false` | Request focus on mount |
| `focusNode` | `FocusNode?` | `null` | Custom focus node |
| `backgroundColor` | `Color` | `#0A0F14` | Canvas background |
| `foregroundColor` | `Color` | `#E6EDF3` | Text color |
| `chromeColor` | `Color` | `#121A24` | Terminal chrome accent color |
| `fontSize` | `double` | `14` | Monospace font size |
| `lineHeight` | `double` | `1.35` | Line height multiplier |
| `fontFamily` | `String?` | `null` | Override the terminal font family |
| `fontFamilyFallback` | `List<String>?` | `null` | Fallback fonts for terminal glyphs |
| `fontPackage` | `String?` | `null` | Package that provides `fontFamily` |
| `letterSpacing` | `double` | `0` | Additional character spacing |
| `cellWidthScale` | `double` | `1` | Manual terminal cell width tuning for prompt glyph alignment |
| `padding` | `EdgeInsets` | `all(12)` | Content padding |
| `palette` | `GhosttyTerminalPalette` | `xterm` | Color palette for indexed ANSI colors |
| `cursorColor` | `Color` | `#9AD1C0` | Cursor fill color |
| `selectionColor` | `Color` | `#665DA9FF` | Selection highlight color |
| `hyperlinkColor` | `Color` | `#61AFEF` | Detected hyperlink text color |
| `renderer` | `GhosttyTerminalRendererMode` | `formatter` | Choose formatter or native render-state painting |
| `interactionPolicy` | `GhosttyTerminalInteractionPolicy` | `auto` | Resolve conflicts between text selection and terminal mouse reporting |
| `touchDragBehavior` | `GhosttyTerminalTouchDragBehavior` | `scroll` | Choose whether finger drags scroll transcript content or select text |
| `showSelectionContextMenu` | `bool` | `true` | Show Flutter's adaptive copy/select-all toolbar for touch selections |
| `selectionContextMenuButtonItemsBuilder` | callback | `null` | Customize the adaptive toolbar buttons for touch selections |
| `onSelectionChanged` | callback | `null` | Called when text selection changes |
| `onCopySelection` | callback | `null` | Called with selection content for clipboard copy |
| `onPasteRequest` | callback | `null` | Called to retrieve clipboard text for paste |
| `onOpenHyperlink` | callback | `null` | Called when a hyperlink is activated |

### Recommended font setup

For more consistent terminal rendering across platforms, use a stable
monospace font together with a symbol fallback. These fonts are supplied by
the host app, not by `ghostty_vte_flutter`, so add them as assets or load them
with a package such as `google_fonts` before using the configuration below. A
good starting point is:

- `Noto Sans Mono` for terminal text
- `Noto Sans Symbols 2` as a fallback for arrows, checkmarks, and other symbols

Example:

```dart
GhosttyTerminalView(
  controller: ctrl,
  fontFamily: 'Noto Sans Mono',
  fontFamilyFallback: const ['Noto Sans Symbols 2'],
)
```

### Renderer modes

```dart
// Formatter mode (default): snapshot-driven, best for scrollback and dense TUIs
GhosttyTerminalView(
  controller: ctrl,
  renderer: GhosttyTerminalRendererMode.formatter,
)

// Render-state mode: native cell-level data, incremental dirty tracking
GhosttyTerminalView(
  controller: ctrl,
  renderer: GhosttyTerminalRendererMode.renderState,
)
```

### Interaction policies

Control how the view handles conflicts between text selection and terminal
mouse reporting:

```dart
// Auto (default): prefer text selection unless the running program enables
// mouse reporting
GhosttyTerminalView(
  controller: ctrl,
  interactionPolicy: GhosttyTerminalInteractionPolicy.auto,
)

// Always prefer text selection
GhosttyTerminalView(
  controller: ctrl,
  interactionPolicy: GhosttyTerminalInteractionPolicy.selectionFirst,
)

// Always forward to terminal mouse reporting
GhosttyTerminalView(
  controller: ctrl,
  interactionPolicy: GhosttyTerminalInteractionPolicy.terminalMouseFirst,
)
```

### Touch input

On touch screens, finger drags scroll the transcript by default. Long-press
starts text selection, shows draggable selection handles, and opens Flutter's
adaptive copy/select-all toolbar. Drag either handle to adjust the highlighted
range; holding a handle near the top or bottom edge pans the terminal selection
through the transcript. If an app wants old desktop-style drag selection on
touch, opt in explicitly:

```dart
GhosttyTerminalView(
  controller: ctrl,
  touchDragBehavior: GhosttyTerminalTouchDragBehavior.selection,
)
```

Touch is not mapped into terminal mouse reporting in `auto` mode, even when the
running program enables mouse reporting. Use `terminalMouseFirst` when a TUI
should receive touch taps and drags as terminal mouse events.

Customize the touch selection toolbar by returning Flutter
`ContextMenuButtonItem`s. The details object includes the selected terminal text,
the active cell selection, the default Copy/Select All buttons, and helpers for
copying, selecting all, and hiding the toolbar:

```dart
GhosttyTerminalView(
  controller: ctrl,
  selectionContextMenuButtonItemsBuilder: (details) {
    return [
      ...details.defaultButtonItems,
      ContextMenuButtonItem(
        label: 'Explain',
        onPressed: () {
          details.hideToolbar();
          explainTerminalText(details.selectedText);
        },
      ),
    ];
  },
)
```

### Selection and clipboard

Wire up selection and clipboard callbacks for copy/paste support:

```dart
GhosttyTerminalView(
  controller: ctrl,
  copyOptions: const GhosttyTerminalCopyOptions(
    trimTrailingSpaces: true,
    joinWrappedLines: false,
  ),
  wordBoundaryPolicy: const GhosttyTerminalWordBoundaryPolicy(
    extraWordCharacters: '._/~:@%#?&=+-',
    treatNonAsciiAsWord: true,
  ),
  onCopySelection: (text) {
    Clipboard.setData(ClipboardData(text: text));
  },
  onPasteRequest: () async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return data?.text;
  },
  onOpenHyperlink: (uri) {
    launchUrl(Uri.parse(uri));
  },
)
```

## Complete example

A full terminal app with shell profile selection, clipboard, and theming:

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghostty_vte_flutter/ghostty_vte_flutter.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeGhosttyVteWeb();
  runApp(const TerminalApp());
}

class TerminalApp extends StatelessWidget {
  const TerminalApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: const TerminalScreen(),
    );
  }
}

class TerminalScreen extends StatefulWidget {
  const TerminalScreen({super.key});
  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen> {
  final _ctrl = GhosttyTerminalController(
    maxScrollback: 10000,
    preferPty: true,
  );

  @override
  void initState() {
    super.initState();
    _startShell();
  }

  Future<void> _startShell() async {
    await _ctrl.startShellProfile(
      profile: GhosttyTerminalShellProfile.auto,
      platformEnvironment: ghosttyTerminalPlatformEnvironment(),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: _ctrl,
          builder: (context, _) => Text(_ctrl.title),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              final launch = _ctrl.activeShellLaunch;
              if (launch != null) {
                await _ctrl.restartLaunch(launch);
              }
            },
          ),
        ],
      ),
      body: GhosttyTerminalView(
        controller: _ctrl,
        autofocus: true,
        backgroundColor: const Color(0xFF0A0F14),
        foregroundColor: const Color(0xFFE6EDF3),
        fontSize: 14,
        fontFamily: 'Noto Sans Mono',
        fontFamilyFallback: const ['Noto Sans Symbols 2'],
        onCopySelection: (text) {
          Clipboard.setData(ClipboardData(text: text));
        },
        onPasteRequest: () async {
          final data = await Clipboard.getData(Clipboard.kTextPlain);
          return data?.text;
        },
      ),
    );
  }
}
```

The example above assumes your app provides those font families. They are not
bundled with `ghostty_vte_flutter`, so include them in your app assets or load
them through a package such as `google_fonts` to avoid platform fallback.

## Web setup

1. **Build the wasm module:**

   ```bash
   cd pkgs/vte/ghostty_vte
   dart run tool/build_wasm.dart
   ```

   This produces `ghostty-vt.wasm` in the Flutter assets directory.

2. **Initialise before `runApp`:**

   ```dart
   await initializeGhosttyVteWeb();
   ```

   This is a no-op on native platforms.

3. **Build for web:**

   ```bash
   flutter build web --wasm
   ```

## Native setup

No manual steps needed. The `ghostty_vte` build hook runs automatically
during `flutter run` and `flutter build`, producing the correct native
library for your target. Just make sure **Zig** and the **Ghostty source**
are available — see the
[`ghostty_vte` README](https://pub.dev/packages/ghostty_vte) for details.

Or download [prebuilt libraries](https://github.com/kingwill101/dart_terminal/releases)
to skip the Zig requirement entirely.

## Related packages

| Package | Description |
|---------|-------------|
| [`ghostty_vte`](https://pub.dev/packages/ghostty_vte) | Core Dart FFI bindings (re-exported by this package) |
| [`portable_pty`](https://pub.dev/packages/portable_pty) | Cross-platform PTY subprocess control |
| [`portable_pty_flutter`](https://pub.dev/packages/portable_pty_flutter) | Flutter controller for PTY sessions |

## License

MIT — see [LICENSE](https://github.com/kingwill101/dart_terminal/blob/master/pkgs/vte/ghostty_vte_flutter/LICENSE).
