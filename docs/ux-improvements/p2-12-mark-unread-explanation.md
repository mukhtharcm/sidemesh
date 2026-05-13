# P2-12 — "Mark unread" purpose is unexplained

## Problem

The session ⋯ overflow menu has a "Mark unread" option with the detail
text "Return this thread to your attention queue."  Most users have no
idea:
- What the "attention queue" is
- When they would ever want to mark a session unread
- That there is an unread state at all (the blue dot is subtle)

The feature is actually useful: you're in a session, you see something
that needs follow-up, but you need to handle it later.  Marking it
unread puts a visible blue dot on the card in the Recent list.  But this
chain of cause-and-effect is invisible.

## Affected files

- `apps/mobile/lib/src/screens/session_screen.dart` —
  `_sessionActionGroups`, the 'unread' action spec
- `apps/mobile/lib/src/widgets/session_row_card.dart` — `_UnreadDot`

## Implementation plan

### Step 1 — Improve the action label and detail

```dart
const _SessionActionSpec(
  value: 'unread',
  label: 'Flag for follow-up',            // ← was 'Mark unread'
  detail: 'Adds a blue dot to this session in your recents list.',
  icon: Icons.flag_rounded,               // ← was mark_chat_unread
),
```

"Flag for follow-up" is immediately understood without needing to know
what "unread" means in this context.

### Step 2 — Show the unread dot more prominently

In `SessionRowCard` (mobile variant), the unread dot currently sits
between the title and the star button — it's 8×8 px and easy to miss.

When `unread == true`, also apply a slightly bolder font weight to the
title and a subtle Mesh status treatment on the row. Do not use a left-edge
accent strip; the redesign direction moved away from that visual pattern.

```dart
MeshStatusBadge(
  label: 'follow-up',
  icon: Icons.flag_rounded,
  tone: MeshStatusTone.queued,
)
```

A compact badge or selected-row treatment makes unread sessions visible
without adding another unexplained edge marker.

### Step 3 — Auto-clear unread on open

When the user opens a session, mark it as read.  This already happens
via `_readStore.markSeen()` in `_SessionScreenState.initState`.  No
change needed here.

### Step 4 — Tooltip on the unread dot itself

On the Recent tab cards, if `unread == true`, add a tooltip to the
blue dot: "Flagged for follow-up — tap to open".

## Acceptance criteria

- The action is labelled "Flag for follow-up" with a flag icon.
- The detail text explains what happens ("blue dot in recents").
- Unread sessions have a compact follow-up status treatment on their row.
- Opening a session clears the flag automatically.
