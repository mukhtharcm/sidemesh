# ghostty_vte_flutter example — Ghostty VT Studio

A full-featured Flutter app that showcases every major API from `ghostty_vte` and
`ghostty_vte_flutter`. Use it as a reference or playground.

The terminal pane now includes:
- shell profile selection (`Auto`, `Bash`, `Zsh`, `User Shell`)
- terminal font family override
- cell width scale tuning for prompt glyph alignment
- Session tab launch diagnostics and `Copy Environment`

## What's included

| Tab | Description |
|-----|-------------|
| **Terminal** | Live PTY shell session using `GhosttyTerminalView` + `GhosttyTerminalController`. Send commands, see output, and test paste safety. |
| **OSC** | Parse Operating System Command payloads and inspect command type / window title. |
| **SGR** | Parse SGR parameters (bold, colors, underline, etc.) and see structured attribute data. |
| **Key Encoder** | Configure key events (action, key, modifiers, Kitty flags) and inspect the exact encoded byte sequence. |
| **Session** | Inspect launch profile, command line, effective environment, and recent activity. |

All tabs include presets, live updating, and an activity log.

## Prerequisites

- **Flutter SDK**
- **Zig** on your `PATH`
- Ghostty source available (see the main [ghostty_vte README](../../ghostty_vte/README.md#ghostty-source-location))

## Run on desktop (native)

```bash
cd pkgs/ghostty_vte_flutter/example
flutter run
```

On desktop, the Terminal tab spawns a real shell subprocess and you can interact
with it directly.

## Run on web

Build the wasm module first from the workspace root:

```bash
task wasm
```

Then:

```bash
cd pkgs/ghostty_vte_flutter/example
flutter run -d chrome
```

On web, the Terminal tab uses a placeholder controller. Connect a remote backend
by calling `controller.appendDebugOutput()` with data from a WebSocket or SSH
proxy.

## Build for release

```bash
# Linux desktop
flutter build linux

# Web (wasm)
flutter build web --wasm
```

## Code walkthrough

The example lives in a single file: `lib/main.dart`.

Key patterns demonstrated:

```dart
// Initialize wasm (no-op on native)
await initializeGhosttyVteWeb();

// Terminal controller
final controller = GhosttyTerminalController();
await controller.startShellProfile(
  profile: GhosttyTerminalShellProfile.cleanBash,
  platformEnvironment: ghosttyTerminalPlatformEnvironment(),
);
controller.write('echo hello\n', sanitizePaste: true);
controller.sendKey(key: GhosttyKey.GHOSTTY_KEY_C, mods: GhosttyModsMask.ctrl, ...);
print(controller.activeShellLaunch?.commandLine);

// OSC parsing
final osc = VtOscParser();
osc.addText('0;My Title');
final cmd = osc.end();
print(cmd.windowTitle);
osc.close();

// SGR parsing
final sgr = VtSgrParser();
final attrs = sgr.parseParams([1, 31, 4]);
sgr.close();

// Key encoding
final encoder = VtKeyEncoder();
final event = VtKeyEvent()
  ..key = GhosttyKey.GHOSTTY_KEY_ENTER
  ..action = GhosttyKeyAction.GHOSTTY_KEY_ACTION_PRESS;
final bytes = encoder.encode(event);
event.close();
encoder.close();
```
