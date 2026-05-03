# P3-17 — Terminal key bar too narrow on small phones

## Problem

`_TerminalKeyBar` at the bottom of the terminal screen renders a
single horizontal row of special-key buttons (Esc, Tab, Ctrl+C, arrow
keys, etc.).  Each button is roughly 36–40 px wide.

On a 375 px phone (iPhone SE, many Androids), this is very fiddly to
tap accurately mid-session.  A mistaken Ctrl+C when you meant Tab can
terminate a running process.

## Affected files

- `apps/mobile/lib/src/screens/terminal_screen.dart` — `_TerminalKeyBar`,
  `_TerminalKey`, key rendering

## Implementation plan

### Step 1 — Audit current key widths

`_TerminalKey` objects have a `widthFactor` property.  Check if any
keys have `widthFactor == 1.0` and are still below 44 px on a 375 px
screen.

### Step 2 — Increase minimum tap target to 44 px

Set a `minWidth: 44` constraint on each key button:

```dart
ConstrainedBox(
  constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
  child: _buildKey(key),
),
```

### Step 3 — Make the key bar horizontally scrollable

If 44 px keys overflow the screen width, make the row scrollable:

```dart
SingleChildScrollView(
  scrollDirection: Axis.horizontal,
  padding: const EdgeInsets.symmetric(horizontal: 8),
  child: Row(
    children: keys.map(_buildKey).toList(),
  ),
),
```

This gives every key enough space without cramping the layout.

### Step 4 — Increase key bar height slightly

Current key bar height allows for compact keys.  Increasing to 48 px
row height makes each button easier to hit:

```dart
SizedBox(
  height: 48,
  child: ...,
),
```

### Step 5 — Add haptic on key press

```dart
onTap: () {
  HapticFeedback.selectionClick();
  widget.onKey(key.sequence);
},
```

`selectionClick` is lightweight — appropriate for keyboard key presses.

## Acceptance criteria

- Every key has a minimum 44×44 tap target.
- Keys that overflow narrow screens are scrollable.
- Haptic click on every key tap.
- No regression on wider screens / tablets.
