# ghostty_vte example

A pure Dart CLI example demonstrating the main `ghostty_vte` APIs.

## What it does

The example runs five demos, printing results to the console:

| Demo | API | Description |
|------|-----|-------------|
| **Paste safety** | `GhosttyVt.isPasteSafe()` | Checks several strings for dangerous control sequences |
| **OSC parser** | `VtOscParser` | Parses an OSC window-title payload |
| **SGR parser** | `VtSgrParser` | Parses bold + red foreground + underline params and a reset |
| **Terminal + formatter** | `VtTerminal` + `VtTerminalFormatter` + `VtAllocator` | Feeds VT content into a terminal, snapshots plain text with both buffered and allocated helpers, emits VT output, then resets |
| **Key encoding** | `VtKeyEvent` + `VtKeyEncoder` | Mirrors cursor-key mode from a terminal and encodes an Up Arrow press |

## Prerequisites

- **Dart SDK >= 3.10**
- **Zig** on your `PATH`, or a usable prebuilt `libghostty-vt`
- Ghostty source available via one of:
  - `GHOSTTY_SRC` environment variable
  - `third_party/ghostty` submodule (in `pkgs/vte/ghostty_vte`)
  - `GHOSTTY_SRC_AUTO_FETCH=1` to clone automatically

## Run

```bash
cd pkgs/vte/ghostty_vte/example
dart pub get
dart run
```

The build hook automatically compiles `libghostty-vt` for your host platform
on the first run.

## Notes

- The example is native-first because it is a CLI app. The same VT terminal,
  formatter, and terminal-driven key encoder APIs now work on web after
  `GhosttyVtWasm.initializeFromBytes(...)`.
- The remaining web gap is the raw allocator bridge on `VtAllocator`; the
  formatter allocated-output helpers work on web via Ghostty's default wasm
  allocator, but arbitrary custom allocator pointers are still native-only.
- See `bin/main.dart` for the full source.
