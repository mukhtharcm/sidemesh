# Changelog

## 0.1.3

- Improved mobile terminal text selection with touch handles, drag-to-extend
  selection, adaptive selection toolbar support, and custom toolbar actions.
- Fixed tap behavior so tapping a cell after an active word selection clears
  the selection instead of replacing it with a single-character highlight.
- Added Android integration coverage for focus, word selection, selection
  clearing, scrolling, resize stability, and toolbar interactions.
- Bumped `ghostty_vte` to `^0.1.3` and `portable_pty` to `^0.0.5`.

## 0.1.2+1

- Use latest ghostty_vte package version

## 0.1.2

- Added `showHeader`, `focusOnInteraction`, and `onTapTerminal` on
  `GhosttyTerminalView` so embedders can hide the terminal chrome row and
  control focus/tap behavior more precisely.
- Improved `renderState` fidelity by using Ghostty's resolved default colors
  directly, tightening whole-run text shaping to stay cell-aligned, and fixing
  terminal mouse coordinate encoding when a header is present.
- Added transcript scrolling APIs on `GhosttyTerminalView`, including external
  `ScrollController`/physics support, a built-in vertical scrollbar, and
  optional auto-follow-on-activity behavior, plus input-triggered jumps back
  to the live cursor while typing even when output auto-follow is disabled.
- Updated formatter-mode cursor painting to prefer the native Ghostty cursor
  position when available, avoiding stale right-edge cursor artifacts while
  keeping formatter text rendering.
- Added custom painting for terminal box-drawing and geometric marker glyphs to
  better match Ghostty/terminal output for borders and single-cell symbols.
- Expanded paint regression coverage for formatter vs `renderState` parity,
  border continuity, circle glyph spacing, headerless rendering, scroll
  behavior, and cursor placement.
- Bumped the `ghostty_vte` dependency to `^0.1.1`.

## 0.1.0+1

- Added external transport hooks on `GhosttyTerminalController` so Flutter apps
  can attach SSH or other remote backends while still using the built-in VT
  parser and renderer.
- Fixed control-key chord handling to send ASCII control bytes for common
  `Ctrl+` shortcuts, including copy-free terminal interactions like `Ctrl+C`.
- Improved snapshot parsing and web/native parity for cursor state, escape
  sequence handling, mouse modes, and formatter metadata.
- Updated the README quick start to a runnable minimal app and bumped the
  `ghostty_vte` dependency to `^0.1.0+2`.

## 0.1.0

- **BREAKING**: Removed regex-based OSC title tracking (`_consumeOscText`,
  `_consumeOscPayload`). Title is now driven by native `onTitleChanged`
  callback.
- **BREAKING**: `resize()` now requires `cellWidthPx` and `cellHeightPx`.
- 7 public callback properties on the controller: `onBell`,
  `onTitleChanged`, `onSize`, `onColorScheme`, `onDeviceAttributes`,
  `onEnquiry`, `onXtversion` (writePty handled internally).
- Controller data getters: `title`, `pwd`, `mouseTracking`, `totalRows`,
  `scrollbackRows`, `widthPx`, `heightPx`.
- New `TerminalRenderModel` abstraction (211 lines).
- Expanded example app with all 8 effect callbacks and live state display.
- Bumped `ghostty_vte` dependency to `^0.1.0`.

## 0.0.3+1

- Bumped `ghostty_vte` dependency to `^0.0.3` for auto-download support.

## 0.0.1+1

- Bumped package version to `0.0.1+1`.

## 0.0.1

- Initial release.
- `GhosttyTerminalView` — CustomPaint-based terminal renderer.
- `GhosttyTerminalController` — ChangeNotifier for shell sessions.
- `initializeGhosttyVteWeb()` — one-liner wasm loader for Flutter web.
- Re-exports all `ghostty_vte` APIs.
