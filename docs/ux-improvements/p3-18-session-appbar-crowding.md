# P3-18 — Session AppBar gets crowded on compact when Stop is visible

## Problem

On compact mobile (< 600 px), the session AppBar title area competes
with the Stop button in the actions list:

```
[← back] [LivePulse] [Session title — truncated—] [⏹ Stop] [⋯]
```

When the session title is long, it truncates aggressively.  The Stop
button is a critical safety action that deserves a clear tap target, but
its presence in the AppBar reduces available title space.

## Affected files

- `apps/mobile/lib/src/screens/session_screen.dart` — AppBar title +
  actions construction (around line 5317)

## Implementation plan

### Step 1 — Move Stop into the ⋯ action sheet (compact mode only)

On compact mode, remove the Stop button from the AppBar actions and
instead surface it as the FIRST prominent action in `_SessionActionSheet`
(already shown on compact via the ⋯ button):

```dart
// In _sessionActionGroups, add Stop at the TOP of Quick moves:
if (_running && _supportsSessionInterrupt)
  _SessionActionSpec(
    value: 'stop',
    label: 'Stop agent',
    detail: 'Interrupt the current turn.',
    icon: Icons.stop_circle_rounded,
    tone: _SessionActionTone.danger,
    active: true,
  ),
```

### Step 2 — Replace the Stop button in AppBar with a visual indicator

When the session is running (compact), the `LivePulse` in the title
already signals activity.  Removing the Stop button from the AppBar
frees space for the full title.

To ensure Stop is still discoverable, make the ⋯ button visually pulse
/ use a warning color while the agent is running:

```dart
MeshIconButton(
  icon: Icons.more_horiz_rounded,
  tooltip: 'Session actions',
  color: _running ? colors.warning : colors.textPrimary,
  onTap: () => ...,
),
```

The orange/amber ⋯ signals "there's something time-sensitive in here."

### Step 3 — Keep Stop in AppBar on non-compact (desktop/tablet)

The existing non-compact layout with the Stop `TextButton.icon` in the
AppBar is fine on wider screens.  Only move it for compact mode.

### Step 4 — Session action sheet: highlight Stop prominently

When `_running` is true and the sheet opens, the Stop action should be
visually prominent:
- Full-width row
- Danger tone (red icon, subtle red tint)
- Placed first in the list before other quick moves

## Acceptance criteria

- Compact AppBar: title has full available width, no Stop button.
- ⋯ button uses warning color while agent is running.
- Session action sheet shows Stop as the first item with danger styling.
- Non-compact: unchanged (Stop remains in AppBar as TextButton).
- Tapping Stop still requires confirmation dialog (existing behavior
  preserved).
