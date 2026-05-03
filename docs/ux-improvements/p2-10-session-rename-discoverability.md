# P2-10 — Session rename is completely hidden

## Problem

Session titles are auto-generated from the first user message and often
unhelpful once truncated ("Fix the authentication bug in the OAuth2...").
The rename feature exists but is buried in `⋯ → Manage → Rename`.

- Tapping the session title in the AppBar does nothing.
- There is no pencil icon or any visual hint that the title is editable.
- Most users never discover rename.

## Affected files

- `apps/mobile/lib/src/screens/session_screen.dart` — AppBar title,
  `_renameSession()`
- `apps/mobile/lib/src/screens/session_screen_header.dart` —
  `_SessionAppBarSubtitle` (compact), `_SessionHeader` (non-compact)

## Implementation plan

### Step 1 — Make the AppBar title tappable when rename is supported

In the `AppBar(title:)` widget, when `_supportsSessionRename` is true,
wrap the title row in a `GestureDetector`:

```dart
title: _supportsSessionRename
    ? GestureDetector(
        onTap: () => unawaited(_renameSession()),
        child: Row(children: [
          if (_running) ...[const LivePulse(), const SizedBox(width: 10)],
          Expanded(
            child: Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Icon(Icons.edit_rounded, size: 14, color: colors.textTertiary),
        ]),
      )
    : Row(children: [...]),   // existing non-tappable version
```

The small `edit_rounded` icon gives a visible affordance without
cluttering the AppBar.

### Step 2 — Improve `_renameSession` dialog

The existing `_renameSession` shows an `AlertDialog` with a text field.
Improve it:
- Pre-select all text in the field so the user can immediately type a
  new name.
- Add `textInputAction: TextInputAction.done` to submit on keyboard Done.
- Show the char count / a 100-char limit.

```dart
Future<void> _renameSession() async {
  ...
  final controller = TextEditingController(text: current)
    ..selection = TextSelection(baseOffset: 0, extentOffset: current.length);
  ...
}
```

### Step 3 — Compact subtitle also tappable

`_SessionAppBarSubtitle` is the `bottom:` of the AppBar in compact mode.
It already handles `onTap: onDetails` (opens the details sheet).  Add a
long-press or a separate pencil icon that calls `onRename`.

Add `onRename` callback to `_SessionAppBarSubtitle` and wire it from
`_SessionScreenState`.

### Step 4 — Rename still available in ⋯ menu

Keep the existing overflow menu entry — it's a discovery path for users
who find the tappable title later.

## Acceptance criteria

- Tapping the session title in the AppBar opens the rename dialog.
- A small edit icon is visible next to the title when rename is supported.
- The rename dialog pre-selects the current title for quick replacement.
- The ⋯ menu Rename entry still works.
- No change when `_supportsSessionRename == false`.
