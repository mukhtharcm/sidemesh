# P2-14 — Destructive storage actions have no danger styling

## Problem

Settings contains two actions that permanently delete data:

1. **Clear session cache** — removes all locally cached session
   transcripts.
2. **Clear all local data** — wipes favorites, read status, session
   cache, all persisted preferences.

Both are presented as ordinary `_ActionRow` items with neutral grey
icons and standard text weight — identical to "Refresh notifications"
or "Reload from host."  The visual weight does not match the
consequence.

A user quickly tapping through settings could trigger "Clear all local
data" without realising the impact.  The confirmation dialog exists, but
the decision to show it starts too late (should be obvious before the
tap, not only after).

## Affected files

- `apps/mobile/lib/src/screens/settings_screen.dart` — storage
  management section, `_ActionRow`

## Implementation plan

### Step 1 — Add a `tone` parameter to `_ActionRow`

```dart
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    ...
    this.tone = _ActionRowTone.neutral,
  });

  ...
  final _ActionRowTone tone;
}

enum _ActionRowTone { neutral, danger }
```

### Step 2 — Style danger rows visually differently

When `tone == danger`:
- Icon color: `colors.danger` instead of `colors.textSecondary`
- Title color: `colors.danger`
- Background: a very faint `colors.dangerMuted` tint on the row

```dart
final iconColor = tone == _ActionRowTone.danger
    ? colors.danger
    : colors.textSecondary;
final titleColor = tone == _ActionRowTone.danger
    ? colors.danger
    : colors.textPrimary;
final rowBg = tone == _ActionRowTone.danger
    ? colors.dangerMuted.withValues(alpha: 0.5)
    : Colors.transparent;
```

### Step 3 — Apply danger tone to destructive actions

```dart
_ActionRow(
  icon: Icons.delete_sweep_rounded,
  title: 'Clear session cache',
  subtitle: 'Removes cached transcripts. Sessions remain on the host.',
  tone: _ActionRowTone.danger,       // ← new
  busy: _busyAction == 'clearCache',
  onTap: () => unawaited(_runStorageAction(key: 'clearCache', ...)),
),
_ActionRow(
  icon: Icons.delete_forever_rounded,
  title: 'Clear all local data',
  subtitle: 'Removes favorites, read state, and all cached data permanently.',
  tone: _ActionRowTone.danger,       // ← new
  busy: _busyAction == 'clearAll',
  onTap: () => unawaited(_runStorageAction(key: 'clearAll', ...)),
),
```

### Step 4 — Add a danger section header

Group these actions under a dedicated section with a clear label:

```dart
_SettingsSection(
  icon: Icons.warning_amber_rounded,
  title: 'Data & storage',
  subtitle: 'Permanent actions. Cannot be undone.',
  children: [...],
),
```

### Step 5 — Improve the confirmation dialog

The existing `showDialog` confirmation should:
- Use `colors.danger` for the confirm button label
- State exactly what will be deleted in the body text
- Use the word "permanently" explicitly

## Acceptance criteria

- Clear cache and Clear all data rows are visually distinct (red icon,
  red title, faint red tint).
- They are grouped under "Data & storage" with a warning subtitle.
- The confirmation dialog uses danger styling on the confirm button.
- All other settings rows are visually unchanged.
