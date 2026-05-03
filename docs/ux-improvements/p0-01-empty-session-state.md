# P0-01 — Empty timeline after session creation

## Problem

When a user creates a new session the app immediately navigates into the
session screen.  Between "I tapped Start session" and "I see the agent
responding" there is a silent gap.

- If `_loading == true` and the timeline is empty: the screen shows
  `MeshLoader` (spinner).  Good.
- Once loading finishes and the timeline is still empty (agent hasn't
  produced any output yet): the screen shows a **completely blank scroll
  area**.  No spinner, no status text, nothing.

The user does not know whether their prompt was received, whether the
agent is thinking, or whether something silently broke.

## Root cause

`session_screen.dart` builds the timeline like this:

```dart
(_loading && timelineEntries.isEmpty)
    ? const MeshLoader()
    : ListView.builder(...)
```

Once `_loading` flips to `false`, even if `timelineEntries` is still
empty, the `MeshLoader` disappears and an empty `ListView` is shown.
There is no branch for `!_loading && timelineEntries.isEmpty && _running`.

`_ComposerStatusStrip` shows "Working…" only when `_thinkingNotifier`
is true — which is set after the first streaming delta arrives, not at
connection time.

## User impact

Every newly created session hits this state.  The window can be
0.5 – 5 seconds depending on model and network.

## Affected files

- `apps/mobile/lib/src/screens/session_screen.dart` — timeline build
- `apps/mobile/lib/src/screens/session_screen_timeline.dart` —
  `_ComposerStatusStrip`

## Implementation plan

### Step 1 — New "connecting" state indicator

Add a `_sessionJustCreated` bool to `_SessionScreenState` that is
`true` when the screen was opened from `CreateSessionSheet` (i.e. the
session has no messages yet and was just launched).

Detect it by checking `_messages.isEmpty && _activities.isEmpty &&
widget.session.createdAt` is within the last 30 s, or by passing an
explicit `isNew: bool` parameter from the navigation call.

### Step 2 — Show a warm empty state instead of blank space

When `!_loading && timelineEntries.isEmpty` replace the blank `ListView`
with a centred column:

```
[pulse animation]
Waiting for agent…
Your prompt was sent. The agent is starting.
```

Use `LivePulse` + body text.  This should disappear automatically once
the first timeline entry appears (the next `setState` from the live
event stream will rebuild).

### Step 3 — Extend `_ComposerStatusStrip` to cover the start-up gap

Add a `ValueNotifier<bool> _connectingNotifier` that is `true` from
the moment the session screen opens until either:
- The first live event arrives, or
- 10 seconds pass (timeout → stop the animation silently)

Pass it to a variant of `_ComposerStatusStrip` so the "Working…"
indicator appears from the very first frame, not just after the first
token.

### Step 4 — Haptic feedback on first agent message

When `_messages` transitions from empty to non-empty for the first
time in a session (detected in `_handleLiveEvent`), call
`HapticFeedback.lightImpact()` to give the user a physical signal that
the agent is responding.

## Acceptance criteria

- Opening a freshly-created session never shows a blank screen.
- The "Waiting for agent…" state is visible until at least one message
  or activity appears.
- The state disappears immediately when output arrives (no delay).
- Does not regress sessions opened from history (those have messages
  immediately).
