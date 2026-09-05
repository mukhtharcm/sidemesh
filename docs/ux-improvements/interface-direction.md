# Interface direction implementation

This tracks the six-phase direction approved in the exported “Quiet Until It
Needs You” artifact and the accompanying implementation plan. The written
corrections take precedence: retain the desktop rail and distinguish attention
counts from machine inventory. Nord, mono, and the user's interface-font choice
remain; system sans is still the default.

## Implementation map

| Phase | Implemented behavior | Main evidence |
| --- | --- | --- |
| 1 — Foundations | Reversed transcript bottom clearance; no unknown context percentage in the subtitle; home paths display `~`; bundled Source Serif 4 and OFL; `proseStyle`; six rules and colour budget in DESIGN.md | Workspace-label and text-style tests; transcript padding inspection |
| 2 — Transcript | Assistant prose on canvas within the reading measure; scoped markdown headings; flat command titles and metadata; daemon command semantics and client argument fallback; interaction-only message actions and repeated-minute suppression; persistent retry and unresolved-composer gating; existing older-history affordance retained | Markdown, live-event, navigation and Codex-history tests; real Codex transcript inspected on Linux |
| 3 — Mobile navigation/composer | Framework back button, no competing sessions drawer; star and filters in overflow; thin subtitle; intrinsic scrolling model/effort controls with readable labels; full model names preserved | Navigation tests, including iOS-style 200-point back gesture; composer capability/layout tests; Android screenshots |
| 4 — Lists | Existing repository/worktree grouping retained; one-line rows and search-only snippets; group metadata removed from rows; mixed providers shown when needed; mobile New session action floats; Machines terminology | RecentPane grouping/search tests and dedicated SessionRowCard tests; macOS list compared with the user's Claude reference |
| 5 — Desktop | Rail retained; Needs review group exposes pending inbox entries in Sessions; quiet machine inventory; bounded transcript; workspace/branch/working-diff strip; one status control opens pending-send and runtime details | Approval fixture inspected on Linux; real macOS branch/diff/composer screenshot; capability tests |
| 6 — Platform/setup | Feature descriptions styled as text; redundant setup skip removed; distinct connection action; native macOS menus; platform-specific command/control modifiers | Onboarding/editor tests; macOS and iOS dev builds; native menu entries inspected through Accessibility |

The list, rail, onboarding and session controls use existing shape tokens in
place of their remaining raw radius literals. This is not a repository-wide
spacing migration: unrelated legacy screens, including browser preview, remain
an incremental burn-down. A blanket grep gate would fail on that existing debt,
so this change does not introduce one.

## Deliberate choices

- Switching between mobile sessions takes Back followed by selecting a session.
  The old drawer and its forwarding callbacks are removed.
- Pinned messages remain accessible from the session overflow menu. Pin and Copy
  on each message appear through interaction rather than permanent footers.
- The git strip uses the existing Review changes action and capability-gated
  working diff. It does not introduce a new server operation.
- The Inbox destination remains the full queue; its naming ticket is separate.
- Repeated provider compatibility notices collapse into one expandable notice.
- Existing daemon instances are not restarted during an in-daemon session. Old
  cached activity records without command arguments cannot be reconstructed by
  the client; the command-label fix requires a daemon built from this change.

## Verification scope

The full Flutter and server suites, static analysis, server build/package check,
and dev macOS/iOS builds have passed during implementation. Android was used for
shared mobile layout inspection; Linux was used for real transcript and pending
approval inspection. The user's shared macOS session was inspected directly.

Physical iOS edge-swipe feel, simultaneous Stop/Jump overlay clearance on a narrow
screen, and native menu focus transfer still need direct interaction checks; the
corresponding navigation/layout implementation must not be mistaken for that
runtime evidence. Windows/Linux modifier selection is implemented, but no native
Windows build was run. Screenshots contain private session data and are shared
through Taildrop rather than committed.
