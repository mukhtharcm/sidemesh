# P1-09 — No feedback after tapping Approve / Reject

## Problem

When the user taps "Approve" or "Reject" on a `_PendingActionCard`, the
card disappears and the agent resumes.  There is:
- No haptic feedback
- No "Approved" / "Rejected" flash or snackbar
- No visual transition — the card just vanishes

On a slow network, the async call takes a moment.  The user doesn't know
if their tap registered.  A second tap (double-tap) can send a duplicate
response which the backend may handle, but shouldn't be necessary.

## Affected files

- `apps/mobile/lib/src/screens/session_screen.dart` — `_respondAction()`
- `apps/mobile/lib/src/screens/session_screen_header.dart` —
  `_PendingActionCard`, `_PendingActionCardState`

## Implementation plan

### Step 1 — Disable the Approve/Reject buttons immediately on first tap

`_PendingActionCardState` should maintain `bool _responding = false`.
When either button is tapped, set `_responding = true` and disable both
buttons:

```dart
ElevatedButton(
  onPressed: _responding ? null : () => _respond(approve: true),
  child: _responding
      ? const SizedBox(width: 14, height: 14,
            child: CircularProgressIndicator(strokeWidth: 1.5))
      : const Text('Approve'),
),
```

This prevents double-tap and gives immediate visual feedback that the
tap was received.

### Step 2 — Haptic feedback on tap

In `_respond()`:

```dart
Future<void> _respond({required bool approve}) async {
  if (_responding) return;
  setState(() => _responding = true);
  HapticFeedback.mediumImpact();   // ← immediate tactile response
  widget.onRespond(...);
}
```

`HapticFeedback.mediumImpact()` is the right weight for a consequential
action confirmation.

### Step 3 — Brief confirmation label before the card disappears

After the response is sent (in `_SessionScreenState._respondAction`),
before clearing `_pendingAction`, briefly show a snackbar:

```dart
final label = switch (response.decision) {
  'approve' => 'Approved',
  'reject'  => 'Rejected',
  _         => 'Responded',
};
showAppSnackBar(context, label);
```

This is a single-word snackbar that auto-dismisses — it confirms the
action without interrupting flow.

### Step 4 — Elicitation / form responses

The same pattern applies to elicitation form submissions in
`_PendingActionCard`.  Add `HapticFeedback.lightImpact()` on the
submit button tap.

## Acceptance criteria

- Tapping Approve or Reject immediately disables both buttons and shows
  a loading spinner.
- Haptic feedback fires on tap.
- A brief snackbar ("Approved" / "Rejected") confirms the action.
- Double-tapping has no effect.
- Works for all action types: command, file change, elicitation, userInput.
