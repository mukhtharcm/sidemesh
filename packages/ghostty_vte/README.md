# ghostty_vte

[![CI](https://github.com/kingwill101/dart_terminal/actions/workflows/vte.yml/badge.svg)](https://github.com/kingwill101/dart_terminal/actions/workflows/vte.yml)
[![pub package](https://img.shields.io/pub/v/ghostty_vte.svg)](https://pub.dev/packages/ghostty_vte)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](https://github.com/kingwill101/dart_terminal/blob/master/pkgs/vte/ghostty_vte/LICENSE)

Dart FFI bindings for [Ghostty](https://github.com/ghostty-org/ghostty)'s
virtual-terminal engine (`libghostty-vt`). Works on **native platforms** and
on the **web** via WebAssembly.

## Features

| Feature | API | Description |
|---------|-----|-------------|
| **Paste safety** | `GhosttyVt.isPasteSafe()` | Detect dangerous control sequences in pasted text |
| **OSC parsing** | `VtOscParser` | Streaming parser for Operating System Command sequences |
| **SGR parsing** | `VtSgrParser` | Parse Select Graphic Rendition attributes (colors, bold, etc.) |
| **Terminal state** | `VtTerminal` | Full terminal emulator with cursor tracking, modes, scrollback, and effect callbacks |
| **Formatter output** | `VtTerminalFormatter` | Snapshot terminal state as plain text, VT sequences, or HTML |
| **Render state** | `VtRenderState` | Incremental cell-level render data for high-fidelity rendering |
| **Key encoding** | `VtKeyEvent` / `VtKeyEncoder` | Encode keyboard events to terminal byte sequences |
| **Grid introspection** | `VtTerminal.gridRef()` | Resolve cell content, style, and hyperlinks at any grid position |
| **Mode queries** | `VtTerminal.getMode()` / `setMode()` | Read and write DEC private modes and ANSI modes |
| **Mouse protocol** | `VtTerminal.mouseProtocolState` | Aggregated mouse-reporting state from terminal mode flags |
| **Web support** | `GhosttyVtWasm` | Load `libghostty-vt` compiled to WebAssembly |

### Platform support

| Platform | Architectures | Build toolchain |
|----------|---------------|-----------------|
| Linux | x64, arm64 | Zig (or [prebuilt](#prebuilt-libraries)) |
| macOS | x64, arm64 | Zig (or prebuilt) |
| Windows | x64, arm64 | Zig (or prebuilt) |
| Android | arm64, arm, x64 | Zig (or prebuilt) |
| iOS | arm64 device, arm64/x64 simulator | Zig (or prebuilt) |
| Web | wasm32 | Zig (or prebuilt) |

## Installation

```yaml
dependencies:
  ghostty_vte: ^0.1.3
```

The native library is compiled automatically by a
[Dart build hook](https://dart.dev/interop/c-interop#native-assets)
the first time you run `dart run`, `dart test`, `flutter run`, or
`flutter build`. You need **Zig >= 0.15** on your `PATH` and access to the
Ghostty source (see [Ghostty source](#ghostty-source) below).

> **Tip:** If you don't want to install Zig, download a
> [prebuilt library](#prebuilt-libraries) instead.

## Quick start

```dart
import 'package:ghostty_vte/ghostty_vte.dart';

void main() {
  // Paste safety
  print(GhosttyVt.isPasteSafe('echo hello'));         // true
  print(GhosttyVt.isPasteSafe('echo hello\nworld'));  // false

  // OSC parsing
  final osc = GhosttyVt.newOscParser();
  osc.addText('0;My Terminal Title');
  final cmd = osc.end(terminator: 0x07);
  print(cmd.windowTitle);  // "My Terminal Title"
  osc.close();

  // SGR parsing
  final sgr = GhosttyVt.newSgrParser();
  final attrs = sgr.parseParams([1, 31, 4]);  // bold + red fg + underline
  for (final a in attrs) {
    print(a.tag);
  }
  sgr.close();

  // Key encoding
  final encoder = GhosttyVt.newKeyEncoder();
  final event = GhosttyVt.newKeyEvent()
    ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
    ..key = GhosttyKey.GHOSTTY_KEY_C
    ..mods = GhosttyModsMask.ctrl
    ..utf8Text = 'c'
    ..unshiftedCodepoint = 0x63;
  final bytes = encoder.encode(event);
  print(bytes);  // [3] — ETX (Ctrl+C)
  event.close();
  encoder.close();

  // Terminal + formatter
  final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
  final formatter = terminal.createFormatter();
  terminal.write('Hello\r\nWorld');
  print(formatter.formatText());           // Hello\nWorld
  print(formatter.formatTextAllocated());  // Hello\nWorld
  formatter.close();
  terminal.close();
}
```

## Terminal

`VtTerminal` is the core terminal emulator. It processes VT byte streams,
tracks cursor state, manages scrollback, and exposes terminal mode flags.

### Creating a terminal

```dart
final terminal = GhosttyVt.newTerminal(
  cols: 80,
  rows: 24,
  maxScrollback: 10000,  // default
);
```

### Writing data

```dart
// Write a UTF-8 string (automatically encoded)
terminal.write('Hello\r\nWorld');

// Write raw bytes
terminal.writeBytes([0x1b, 0x5b, 0x31, 0x6d]);  // ESC [ 1 m (bold)

// Full reset
terminal.reset();
```

### Resizing

`resize` accepts optional pixel dimensions for accurate size reporting
(used by programs that query terminal pixel size via escape sequences):

```dart
terminal.resize(cols: 120, rows: 40);

// With pixel dimensions for accurate size reporting
terminal.resize(
  cols: 120,
  rows: 40,
  cellWidthPx: 8,
  cellHeightPx: 16,
);
```

### Terminal properties

```dart
print(terminal.cols);             // 80
print(terminal.rows);             // 24
print(terminal.maxScrollback);    // 10000

// Cursor
print(terminal.cursorPosition);   // (x: 5, y: 2)
print(terminal.cursorX);          // 5
print(terminal.cursorY);          // 2
print(terminal.cursorVisible);    // true
print(terminal.cursorPendingWrap); // false
print(terminal.cursorStyle);      // VtStyle(...)

// Screens
print(terminal.isPrimaryScreen);    // true
print(terminal.isAlternateScreen);  // false

// Scrollbar
final sb = terminal.scrollbar;
print(sb.viewportTop);
print(sb.viewportBottom);
print(sb.totalRows);

// Kitty keyboard protocol
print(terminal.kittyKeyboardFlags);
```

### Terminal modes

Read and write DEC private modes and ANSI modes:

```dart
// Check if a mode is set
final bracketedPaste = terminal.getMode(VtModes.bracketedPaste);
print(bracketedPaste);  // false

// Set a mode
terminal.setMode(VtModes.bracketedPaste, true);

// Common modes available via VtModes:
// VtModes.cursorKeys, VtModes.reverseVideo, VtModes.origin,
// VtModes.autoWrap, VtModes.cursorVisible, VtModes.bracketedPaste,
// VtModes.focusEvent, VtModes.altScroll, VtModes.x10Mouse,
// VtModes.normalMouse, VtModes.buttonMouse, VtModes.anyMouse,
// VtModes.sgrMouse, VtModes.sgrPixelsMouse, VtModes.urxvtMouse,
// VtModes.utf8Mouse, ...
```

### Mouse protocol state

Get the aggregated mouse-reporting state derived from terminal mode flags:

```dart
final mouse = terminal.mouseProtocolState;
print(mouse.enabled);       // true/false
print(mouse.trackingMode);  // GhosttyMouseTrackingMode.GHOSTTY_MOUSE_TRACKING_ANY
print(mouse.format);        // GhosttyMouseFormat.GHOSTTY_MOUSE_FORMAT_SGR
print(mouse.focusEvents);   // true/false
print(mouse.altScroll);     // true/false
```

### Scrolling

```dart
terminal.scrollToTop();
terminal.scrollToBottom();
terminal.scrollBy(-5);   // scroll up 5 rows
terminal.scrollBy(10);   // scroll down 10 rows
```

### Grid introspection

Resolve cell content, style, and hyperlinks at any position in the
terminal grid:

```dart
// Active screen coordinates (zero-based)
final cell = terminal.activeCell(0, 0);
print(cell.codepoint);
print(cell.graphemeText);  // full grapheme cluster
print(cell.style);         // VtStyle with colors, bold, italic, etc.
print(cell.hyperlink);     // OSC 8 hyperlink URI, if any

// Other coordinate systems
final vpCell = terminal.viewportCell(10, 5);
final scrCell = terminal.screenCell(0, 100);
final histCell = terminal.historyCell(0, 0);
```

### Terminal effect callbacks

The terminal can invoke callbacks when it needs to communicate back to the
host (e.g. responding to device-status reports). These use
`NativeCallable.isolateLocal` under the hood, so closures work directly:

```dart
// Called when the terminal needs to write response bytes back to the PTY
terminal.onWritePty = (Uint8List data) {
  // Forward DSR responses, mode reports, etc. to the PTY
  ptyProcess.stdin.add(data);
};

// Clear the callback
terminal.onWritePty = null;
```

The `Uint8List` passed to `onWritePty` is only valid for the duration of
the callback. Copy it if you need it to persist.

### Cleanup

Always close terminals and formatters when done:

```dart
formatter.close();
terminal.close();  // also cleans up any registered callbacks
```

## Formatter

The formatter snapshots terminal state as plain text, VT sequences, or HTML:

```dart
final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
final formatter = terminal.createFormatter(
  const VtFormatterTerminalOptions(
    emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_PLAIN,
    trim: true,
  ),
);

terminal.write('Hello\r\n\x1b[31mWorld\x1b[0m');
print(formatter.formatText());  // Hello\nWorld
```

### VT output with styles and cursor

```dart
final formatter = terminal.createFormatter(
  const VtFormatterTerminalOptions(
    emit: GhosttyFormatterFormat.GHOSTTY_FORMATTER_FORMAT_VT,
    extra: VtFormatterTerminalExtra(
      screen: VtFormatterScreenExtra(style: true, cursor: true),
    ),
  ),
);

final snapshot = formatter.formatBytes();
print(snapshot);
```

### Allocated output

The high-level allocated-output helpers use a Dart-owned allocator internally so
the returned buffer can be safely released from Dart:

```dart
print(formatter.formatTextAllocated());

// Or use a specific allocator
final text = formatter.formatTextAllocatedWith(VtAllocator.dartMalloc);
```

## Render state

For high-fidelity rendering, use `VtRenderState` to get incremental
cell-level data with dirty tracking:

```dart
final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
final renderState = terminal.createRenderState();

terminal.write('Hello World');
renderState.update();

print(renderState.cols);    // 80
print(renderState.rows);    // 24
print(renderState.dirty);   // dirty state enum

// Iterate visible rows and cells for custom rendering
// (See ghostty_vte_flutter for a full rendering implementation)

renderState.close();
terminal.close();
```

## Paste safety

```dart
GhosttyVt.isPasteSafe('echo hello');       // true
GhosttyVt.isPasteSafeBytes(utf8Bytes);     // true
```

## OSC parser

```dart
final parser = GhosttyVt.newOscParser();
parser.addText('0;Window Title');
final cmd = parser.end(terminator: 0x07);
print(cmd.windowTitle);
parser.close();
```

## SGR parser

```dart
final parser = GhosttyVt.newSgrParser();
final attrs = parser.parseParams([38, 2, 255, 128, 0]);  // orange fg
print(attrs.first.rgb);  // VtRgbColor(r: 255, g: 128, b: 0)
parser.close();
```

## Key encoder

```dart
final encoder = GhosttyVt.newKeyEncoder();
final event = GhosttyVt.newKeyEvent();

event
  ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS
  ..key = GhosttyKey.GHOSTTY_KEY_ARROW_UP
  ..mods = 0
  ..utf8Text = '';

print(encoder.encode(event));  // [27, 91, 65] — ESC [ A

// Encoder options
encoder
  ..cursorKeyApplication = true   // DEC mode 1
  ..keypadKeyApplication = true   // DEC mode 66
  ..altEscPrefix = true           // Alt sends `ESC` prefix
  ..kittyFlags = GhosttyKittyFlags.all;

// Sync encoder options from terminal mode state
final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
terminal.write('\x1b[?1h');
encoder.setOptionsFromTerminal(terminal);

event.close();
encoder.close();
terminal.close();
```

| Option | Property | Description |
|--------|----------|-------------|
| Cursor key application | `cursorKeyApplication` | DEC mode 1 — arrows emit `ESC O` instead of `ESC [` |
| Keypad application | `keypadKeyApplication` | DEC mode 66 |
| Alt ESC prefix | `altEscPrefix` | Alt key sends `ESC` prefix |
| modifyOtherKeys | `modifyOtherKeysState2` | xterm modifyOtherKeys mode 2 |
| Kitty protocol | `kittyFlags` | Bit flags from `GhosttyKittyFlags` |

## Native allocator bridge

```dart
final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
final formatter = terminal.createFormatter();
terminal.write('Hello');

final text = formatter.formatTextAllocatedWith(VtAllocator.dartMalloc);
print(text);

formatter.close();
terminal.close();
```

`VtAllocator.dartMalloc` exposes a `GhosttyAllocator*` backed by Dart's
`malloc`/`free` and is intended for advanced native callers that need a safe
allocator for raw generated bindings.

## Ghostty source

The build hook looks for Ghostty source code in this order:

1. **`$GHOSTTY_SRC`** environment variable pointing to a directory with
   `build.zig` and `include/ghostty/vt.h`.
2. **`third_party/ghostty/`** git submodule inside the package.
3. **Auto-fetch** — set `GHOSTTY_SRC_AUTO_FETCH=1` and the build hook will
   `git clone` Ghostty automatically.

```bash
# Option A: submodule
git submodule add https://github.com/ghostty-org/ghostty third_party/ghostty

# Option B: environment variable
export GHOSTTY_SRC=/path/to/ghostty

# Option C: auto-fetch
export GHOSTTY_SRC_AUTO_FETCH=1
```

## Prebuilt libraries

Prebuilt binaries for every platform are attached to each
[GitHub release](https://github.com/kingwill101/dart_terminal/releases).

The easiest way to get them is the built-in setup command:

```bash
dart run ghostty_vte:setup
```

This downloads the correct library for your host platform into
`.prebuilt/<platform>/` at your project root. The build hook will find it
automatically — **no Zig install required**.

You can also specify a release tag or target platform:

```bash
dart run ghostty_vte:setup --tag ghostty_vte-v0.1.1 --platform macos-arm64
```

**Monorepo users** can download all prebuilt libs at once:

```bash
dart run tool/prebuilt.dart --tag v0.0.2
```

You can also set the `GHOSTTY_VTE_PREBUILT` environment variable to point
directly at a prebuilt `libghostty-vt.so` / `.dylib` / `.dll` file.

> **Tip:** Add `.prebuilt/` to your `.gitignore`.

## Web usage

On web, the VT terminal, formatter, parser, and key-encoding APIs work after
loading the wasm module:

```dart
import 'package:ghostty_vte/ghostty_vte.dart';

Future<void> main() async {
  // Fetch and initialise the wasm module
  final response = await window.fetch('ghostty-vt.wasm'.toJS).toDart;
  final buffer = await response.arrayBuffer().toDart;
  await GhosttyVtWasm.initializeFromBytes(buffer.toDart.asUint8List());

  final terminal = GhosttyVt.newTerminal(cols: 80, rows: 24);
  final formatter = terminal.createFormatter();

  terminal.write('hello\r\nweb');
  print(GhosttyVt.isPasteSafe('hello'));
  print(formatter.formatText());

  formatter.close();
  terminal.close();
}
```

> **Flutter web?** Use the companion package
> [`ghostty_vte_flutter`](https://pub.dev/packages/ghostty_vte_flutter) which
> handles wasm loading from Flutter assets automatically.
>
> The high-level VT terminal APIs now work on web. The remaining web-only gap is
> the raw allocator bridge (`VtAllocator.pointer`, `copyBytesAndFree`, and
> `freePointer`). `formatBytesAllocated()` and `formatTextAllocated()` work on
> web by using Ghostty's default wasm allocator and freeing the returned buffer
> with the wasm convenience helpers.

## Related packages

| Package | Description |
|---------|-------------|
| [`ghostty_vte_flutter`](https://pub.dev/packages/ghostty_vte_flutter) | Flutter terminal widgets + wasm initialiser |
| [`portable_pty`](https://pub.dev/packages/portable_pty) | Cross-platform PTY subprocess control |
| [`portable_pty_flutter`](https://pub.dev/packages/portable_pty_flutter) | Flutter controller for PTY sessions |

## License

MIT — see [LICENSE](https://github.com/kingwill101/dart_terminal/blob/master/pkgs/vte/ghostty_vte/LICENSE).
