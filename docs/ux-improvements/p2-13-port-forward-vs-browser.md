# P2-13 — Open vs. Remote browser preview distinction unclear

## Problem

The port-forward card shows two "view in browser" actions:

1. **Open** / **Open in browser** — sends the tunnel URL to the phone's
   own browser (Safari / Chrome).
2. **Remote browser** — starts Chromium headlessly on the server, streams
   the rendered pixels to the app via WebSocket.

These do fundamentally different things, but their labels don't make the
distinction clear.  A user who taps "Remote browser" expecting their
phone's browser to open is confronted with a live video stream of a
remote desktop browser, which is confusing and potentially alarming.

## Affected files

- `apps/mobile/lib/src/screens/port_forward_screen.dart` —
  `_PortForwardCard`, action buttons
- `apps/mobile/lib/src/screens/browser_preview_screen.dart` — any
  header text

## Implementation plan

### Step 1 — Rename the buttons with explicit scope labels

| Before | After |
|--------|-------|
| "Open" | "Open on this device" |
| "Remote browser" | "Preview on host (Chromium)" |

```dart
OutlinedButton.icon(
  onPressed: onPreview,
  icon: const Icon(Icons.open_in_browser_rounded, size: 16),
  label: const Text('Open on this device'),
),
OutlinedButton.icon(
  onPressed: onRemoteBrowserPreview,
  icon: const Icon(Icons.monitor_rounded, size: 16),
  label: const Text('Preview on host'),
),
```

### Step 2 — Add a tooltip / subtitle explaining the remote preview

Wrap "Preview on host" in a `Tooltip`:

```dart
Tooltip(
  message: 'Streams a Chromium browser running on the server — '
      'useful when the app requires the server\'s local network.',
  child: OutlinedButton.icon(...),
),
```

### Step 3 — Browser preview screen header clarification

In `_PreviewHeader`, the header shows the preview URL and status.
Add a subtitle line:

```dart
Text(
  'Streaming from ${widget.preview.targetHost}',
  style: monoStyle(color: colors.textTertiary, fontSize: 11),
),
```

This makes it immediately clear the browser is running on the remote
machine, not locally.

### Step 4 — Port-forward card: explain the difference inline

Add a compact info line below the action buttons when both are shown:

```dart
_CompactInfoLine(
  icon: Icons.info_outline_rounded,
  text: '"Open on device" uses your phone\'s browser. '
      '"Preview on host" streams Chromium from the server.',
),
```

Only show when `localUri != null && hasBrowserPreview`.

## Acceptance criteria

- Button labels unambiguously indicate where the browser runs.
- Tooltips explain the remote-preview mechanism.
- The browser preview screen header shows "Streaming from [host]".
- Users who accidentally open remote preview understand what they're
  seeing immediately.
