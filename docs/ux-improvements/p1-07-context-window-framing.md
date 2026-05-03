# P1-07 — "ctx X% left" framing is backwards-sounding

## Problem

The context window pill in the session header reads e.g.:

```
ctx 74% left
```

This means 74 % of the context window is **unused** — a good sign.
But the phrase "X% left" implies scarcity ("only X% remaining before
something bad happens").  At 74% it feels fine; at 10% it reads
correctly.  But at 90% a user might read "90% left" as "almost full"
when it means the opposite.

The `_contextUsageLabel` function in `session_screen_header.dart`
produces this string.

## Affected files

- `apps/mobile/lib/src/screens/session_screen_header.dart` —
  `_contextUsageLabel()`, `_contextUsageShortLabel()`

## Implementation plan

### Step 1 — Change the label to "X% used"

```dart
String? _contextUsageLabel(SessionRuntimeSummary? runtime) {
  final ctx = runtime?.telemetry?.contextWindow;
  if (ctx == null || ctx.tokenLimit <= 0) return null;
  if (ctx.currentTokens == null) {
    return '?/${_formatTokenLimit(ctx.tokenLimit)} ctx';
  }
  final usedPercent = ((ctx.currentTokens! / ctx.tokenLimit) * 100)
      .clamp(0, 100)
      .round();
  return '$usedPercent% ctx used';
}
```

### Step 2 — Change the short label to match

```dart
String? _contextUsageShortLabel(SessionRuntimeSummary? runtime) {
  final ctx = runtime?.telemetry?.contextWindow;
  if (ctx == null || ctx.tokenLimit <= 0) return null;
  if (ctx.currentTokens == null) return '?%';
  final usedPercent = ((ctx.currentTokens! / ctx.tokenLimit) * 100)
      .clamp(0, 100)
      .round();
  return '$usedPercent%';
}
```

### Step 3 — Adjust tone thresholds

The existing `_contextUsageTone` uses `used >= 0.9 → danger` and
`used >= 0.75 → warning`.  These are correct percentages for "used"
framing — no change needed.

### Step 4 — Update `buildRuntimeHighlights` in `session_runtime.dart`

The same "ctx X% left" string is produced in `buildRuntimeHighlights`:

```dart
final percent = ((1 - (context.currentTokens! / context.tokenLimit)) * 100)
    .clamp(0, 100)
    .round();
labels.add('ctx $percent% left');
```

Change to:

```dart
final usedPercent = ((context.currentTokens! / context.tokenLimit) * 100)
    .clamp(0, 100)
    .round();
labels.add('ctx $usedPercent% used');
```

## Acceptance criteria

- The context pill reads "12% ctx used" (low usage) or "91% ctx used"
  (nearly full).
- The danger/warning tone thresholds are unchanged.
- Both the full label and compact percentage label are updated.
- `buildRuntimeHighlights` in `session_runtime.dart` is updated to
  match.
