# Mobile UI/UX Audit (autonomous pass)

This document records the findings of an autonomous UI/UX audit of the
Sidemesh Flutter app, the rationale for each fix, and the sources used
when prioritising changes. It is intentionally brief — every item here
maps to a commit on the `ui-ux-audit` branch.

## Methodology

The audit combined:

1. **Static analysis** of `apps/mobile/lib/src/` (45 kLOC of Dart):
   counts of `fontSize:`, `iconSize:`, `IconButton`, `tooltip`,
   `Semantics`, `RefreshIndicator`, `SnackBar`, etc.
2. **Targeted reads** of high-traffic screens: `home_screen.dart`,
   `session_screen*.dart`, `settings_screen.dart`,
   `onboarding_screen.dart`, key reusable widgets.
3. **Industry best-practice review** focused on common mistakes that
   AI/LLM coding assistants make when generating UI code, and on
   mobile-first mobile app UX in 2025/2026. Sources include Apple HIG,
   Material 3 guidelines, [GenDesigns "15 mistakes"][gd], [0xminds AI
   mobile UI guide][0x], the Trinetix [AI design hallucination][trx]
   piece, and a 2025 [systematic literature review of LLMs in
   UI/UX][slr].

[gd]: https://gendesigns.ai/blog/ai-generated-ui-mistakes-how-to-fix
[0x]: https://0xminds.com/blog/guides/ai-mobile-responsive-prompts-tutorial
[trx]: https://www.trinetix.com/insights/ai-design-hallucination
[slr]: https://arxiv.org/html/2507.04469v2

## High-impact findings

### 1. Tap targets below 44 pt

Apple and Google both publish a 44 pt / 48 dp minimum for any
interactive element. The codebase contains several offenders:

- `widgets/app_snackbar.dart` — dismiss IconButton `iconSize: 16`
  inside an even smaller hit box.
- `screens/home_screen.dart` — search-clear IconButton
  `iconSize: 16`, view-mode picker reduced to a 32×32 box.
- `screens/desktop_shell.dart` — desktop close button
  `iconSize: 18`.

AI codegen consistently undershoots this minimum because most
training data is desktop-oriented. The fix is mechanical: raise the
iconSize and ensure the parent is at least 44 pt tall.

### 2. Microscopic typography

`grep` found **~140 occurrences of `fontSize:` between 9 and 13 pt**
across the screens, mostly in `session_screen_timeline.dart`,
`inspector/`, and the bottom navigation bar (`fontSize: 11`).
Apple HIG recommends 11 pt as an absolute minimum and 13 pt for
secondary text; Material 3's `labelSmall` is 11 pt only for desktop
chrome. On a phone, anything < 12 pt is hard to read in sunlight or
for users with mild low vision.

Approach: bump every `9–11 pt` body / label to `12 pt` minimum and
every secondary metadata label to `13 pt`. Monospaced metadata in
the timeline is allowed to stay at `11 pt` but no smaller.

### 3. Color-only status (no Semantics labels)

There is **exactly one `Semantics` widget** in the entire app, but
status is communicated heavily through coloured dots, badges, and
chips:

- Running / idle / error dots on session rows.
- Active / disabled host indicators.
- Approval-needed badges in the bottom nav.

Screen readers see nothing. This violates WCAG 1.4.1 (Use of
Color) and 1.3.1 (Info and Relationships). Each status surface
should expose a meaningful `Semantics(label: …)` and a textual fall
back.

### 4. Unlabeled icon-only buttons

There are 94 `IconButton`s but only ~68 `tooltip:` properties. The
remaining ~26 expose nothing to VoiceOver / TalkBack. Add `tooltip`
on every `IconButton` — tooltips double as `Semantics.label` on
mobile.

### 5. Hidden power features

Several "power" features are essentially invisible to a new user:

- **Recent-sessions view modes** (flat / by working dir / by host)
  are tucked behind the search field's prefix icon — a 32×32 button
  with no label. Users who don't tap the search bar will never find
  it.
- **Pull-to-refresh** is wired up on most lists but never advertised
  in empty states.
- **Multi-host fleet** is the product's flagship capability, yet the
  empty Hosts tab only shows a single "Pair a host" CTA without
  explaining why you'd want more than one.
- **Keep-screen-awake**, screenshot attachments, voice input, and
  the inspector are buried in settings or deep menus.

Apple's recent CHI 2026 preview, the Trinetix "AI design
hallucination" report, and the GenDesigns guide all converge on the
same lesson: **AI-generated UIs underweight discoverability**
because LLMs reproduce the visual surface of an app without the
empathy that surfaces affordances.

Mitigation: rewrite the Recent / Hosts empty states as short
"feature tours" with concrete next steps, and expose the view-mode
switch as its own labelled control rather than as a search-field
adornment.

### 6. Empty / loading / error state inconsistency

`grep` found 46 empty-state references and 37 loading indicators,
but they are styled inconsistently — some use `CircularProgressIndicator`
centred in the screen, some use a small inline spinner, some show a
text-only "No sessions" with no illustration or action. The
GenDesigns piece flags this exact failure mode ("only prompt for
the happy path"). A single `MeshEmptyState` widget already exists
in `widgets/mesh_widgets.dart` — push the remaining ad-hoc empty
states through it.

## Out of scope

- Server / daemon code (per user instruction).
- Wholesale visual redesign — the Mesh design tokens
  (`theme/app_tokens.dart`) are already coherent; the issues are in
  *how* they are applied.
- Localisation — flagged as future work.

## Roadmap (commits on this branch)

1. `docs(ui-ux): add autonomous audit findings` — this file.
2. `fix(mobile): raise tiny tap targets and font sizes to mobile
   minimums` — addresses §1 and §2.
3. `feat(mobile): make session running / idle status accessible`
   — addresses §3 and §4 for the most visible status surfaces.
4. `feat(mobile): surface view modes and power features in empty
   states` — addresses §5 and §6 for Recent and Hosts tabs.
5. Self-review rounds, each as its own commit.
