# Session detail screen — UI/UX audit

> Snapshot taken on the `main` branch (commit `96bdfbc`). The audit covers
> `apps/mobile/lib/src/screens/session_screen*.dart` plus the supporting widgets
> in `apps/mobile/lib/src/widgets/`. Findings are ordered by user-visible
> impact; the PR that ships alongside this doc tackles the **High** priority
> items.

## High priority — fixed in this PR

### 1. Blank message bubbles in the timeline
`SessionMessage.hasVisibleContent` only inspected `text` and `attachments`, and
the timeline didn't even consult it before rendering. Worse, the
`ContentBlock.fromJson` factory returned `TextBlock('')` whenever it received
an unknown or empty block, polluting `message.content` with empty siblings.

The combined effect: any assistant message that finished as "thinking only"
(common during cold starts and provider warning streams) rendered as a
mysterious empty bubble with just a timestamp.

**Fix**

- `ContentBlock.fromJson` is now a nullable static factory that returns `null`
  for unknown or empty blocks. `SessionMessage.fromJson` filters those out and
  only keeps blocks with non-trivial content.
- `hasVisibleContent` now also considers populated `TextBlock`/`ThinkingBlock`
  entries.
- `_buildTimelineEntries` filters non-renderable messages from both the live
  and optimistic streams before sorting.

### 2. Thinking/reasoning block redesign
The previous block was a plain text + chevron row that stayed collapsed by
default and, when expanded, used a 200px scrollable muted container. Two
problems:

1. **Always-collapsed-by-default hides what the user wants to see most.**
   While the assistant is mid-response, "Thinking…" is the only signal —
   keeping it hidden behind a tap defeats the purpose.
2. **Visual weight didn't match the rest of the bubble palette** (no border,
   tiny icon, weak hierarchy).

**Fix** — `_ReasoningBlock` was redesigned:

- Card-like container with an accent left rail (matches the rest of the design
  system) so it reads as a distinct block but stays subordinate to the message
  body.
- **Open by default** for live or text-less messages — no tap required to see
  the reasoning while it's streaming.
- Auto-collapse-by-default (still tappable) only once the assistant has
  finalized answer text alongside the reasoning, so completed messages stay
  scannable.
- Live state shows a `LivePulse` instead of a static icon; static state shows
  `psychology_alt_outlined`.
- Header copy switches between "Thinking" (live) and "Reasoning" (final).

### 3. `ANSWER` / `COMMENTARY` phase header noise
The phase pill rendered above every assistant message — even ones that contain
only a thinking block, where the phase label is meaningless.

**Fix** — only render the phase header when the message actually has answer
content (`hasAnswer`).

### 4. Unpinned vs. pinned icon
`_MessagePinButton` used `Icons.push_pin_rounded` for both states, so the
button gave no visual feedback for "not yet pinned".

**Fix** — outlined glyph (`Icons.push_pin_outlined`) when unpinned, filled
rounded glyph when pinned.

### 5. Footer condition redundancy
The footer row guard was `canPin || (!isUser && hasText) || hasText`, which
simplifies to `canPin || hasText`. Cleaned up.

## Medium priority — known issues, not in this PR

These are notable but defer cleanly to follow-ups (most need design input or
larger refactors):

- **Three stacked status strips above the composer.** `_PendingSendStrip`,
  `_RuntimeSignalStrip`, and `_ComposerStatusStrip` can all render together,
  consuming a lot of vertical space on phones. Worth merging into a single
  composable strip that shows the most relevant signal first and demotes the
  rest to a kebab.
- **`_ActivityCard` pill explosion.** When expanded, a command activity can
  show 6+ pills (`turn`, `exit`, duration, source, `pty`, `stdin`,
  `interactive`, `command actions`). They're individually useful but together
  feel like noise. Group: `status` (already a separate pill) + a single
  collapsed "details" chip.
- **Per-message timestamps for user messages.** Showing a timestamp under
  every user bubble is redundant when messages are minutes apart. Recommend
  only showing the timestamp on hover/long-press, or grouping under day
  separators that already exist.
- **`_PlanUpdateCard` sits inside the timeline as an `ExpansionTile` with
  `initiallyExpanded: true`,** but the surrounding `MeshCard` already has its
  own visual weight. Result: doubled padding, low information density. Should
  either flatten the expansion tile or shrink the card padding.
- **Cached transcript strip wording.** "Cached transcript · waiting for latest
  host snapshot" buries the fact that the user is offline. Lead with the
  state, follow with the recovery action.
- **Reasoning block doesn't honour `summary: true`.** Some providers send a
  pre-summarized chain-of-thought; we currently render the same way. Worth a
  visual differentiation (e.g., "Summary" label).

## Low priority — polish opportunities

- `_DaySeparator` renders even on the very first message of the session —
  consider suppressing the leading "Today".
- `_MessageCopyButton` and `_MessagePinButton` have nearly identical layouts
  but live as separate widgets. Could share a `_MessageActionChip` to keep
  iconography/spacing consistent forever.
- `_MarkdownMessageBody` always re-creates the underlying `MarkdownContent` on
  every rebuild even when the text is identical (live messages stream this
  hot path). A `const`/memoized variant keyed on text would help frame budget
  on long transcripts.
- The local-image attachment fallback says "Loading image..." with three dots
  — replace with `…` (ellipsis) to match the rest of the app.
- `_RuntimeDetailChip` truncates labels at 240px but doesn't show a tooltip
  with the full value. Add `Tooltip` for accessibility.

## Other screens — quick read

- **`home_screen.dart`** — generally clean. The most actionable fix is the
  empty-state copy reuse of `hasVisibleContent`, which inherits the `models`
  improvement from this PR.
- **`session_window_screen.dart`** — the multi-pane shell is solid but the
  inspector sidebar on tablets has no minimum-width safety, so on small
  landscape phones it can squish to ~100px. Cap the message list min width
  before allowing the inspector to grow.
- **`settings_screen.dart`** — the appearance sheet (`appearance_sheet.dart`,
  834 lines) is starting to feel like a junk drawer. Worth splitting into
  themed/typography/density sections in a later pass.
- **`onboarding_screen.dart`** — fine.
- **`file_browser_screen.dart` / `file_viewer_pane.dart`** — fine; the
  diff/code rendering is reused from `widgets/diff_view.dart` and
  `syntax_code_block.dart` which already match the design system.

## Verification

- `flutter analyze` → No issues found.
- `flutter test test/live_event_models_test.dart` → 4 tests pass (covers the
  `ContentBlock` round-trip).
- `npm run typecheck` → clean.
