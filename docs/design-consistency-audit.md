# Design consistency audit — 5 September 2026

The Flutter client is shared by desktop and mobile. This audit searches its
screens, widgets, themes, and tests. Server and provider behavior is outside
this design change. The public website has a separate design scope.

## Shared causes fixed

| Area | Cause | Change |
| --- | --- | --- |
| Font selector and session defaults | Old dropdowns used a separate popup style | Use `AppSelect` and the shared menu theme |
| Browser controls and machine menus | Local popup implementations differed from session menus | Use `AppMenuButton` and `AppMenuItem` |
| Request form choices | Another dropdown implementation | Use the same selector; keep response validation |
| Dialogs | Local radius and Material defaults differed | Shared 12 px dialog radius; remove image dialog override |
| Agent selection | Custom 28 px floating sheet with its own shadow | Use `MeshBottomSheetScaffold` |
| Desktop sheets | Mobile drag handle and large corners | No handle on wide layouts; shared dialog corners |
| Model and thinking choices | Inspector and modal used different layouts | Compact anchored desktop choices; one sheet on mobile |
| Message actions | Copy and Pin required a menu | Direct icons on hover or focus; visible on touch devices |
| Component states | Local size, selection, and hover rules | Theme owns menu, button, switch, and segmented-control styles |

No `DropdownButton` or `DropdownButtonFormField` remains in `lib/src`.
Two pointer-position approval menus still use `showMenu`. They inherit the
shared popup theme. Their approval choices and response handling are preserved.

## Follow-up changes

- Replaced the audited local corner values in the browser, machine details,
  transcript search, welcome view, onboarding, and image controls with shared
  component shapes. Removed the unused `theme_picker.dart` implementation.
- Added one borderless input decoration for fields with an outer border.
  Browser, composer, search, and editor fields now suppress all inherited
  enabled and focused borders. The browser keeps one visible focus outline.
- Aligned the model search icon and field on one row.
- Removed the separate machine-choice dialog before a new session. The draft
  has a machine selector. A machine change keeps task text and attachments,
  clears the old folder, and reloads provider choices for the new machine.
- Session settings use a bounded desktop form with aligned value controls.
  Mobile retains full-width rows and touch controls.
- The machine editor fits its content on desktop. Fields have labels above
  them. Cancel and Save are adjacent below the form. Mobile keeps a scrollable
  page and actions above the keyboard.
- Removed duplicate outlines from custom dialog wrappers.
- Set standard visual density on themed buttons. Flutter's desktop density
  must not reduce the visible button below the shared 32 px height.

These fixes cover the reported components and the earlier audit list. They do
not establish that every screen has had a complete visual review.

Palette definitions, syntax colors, terminal colors, image backgrounds, and video
control overlays are not general UI color errors. Do not replace them with one
canvas color. They have a separate content or contrast purpose.

## Verification

- Flutter analysis passed.
- All 392 Flutter tests passed, including browser actions, request controls,
  settings navigation, picker selection, and message hover/focus behavior.
- The macOS development build and iOS simulator build passed.
- Desktop and mobile session layouts were rendered in light and dark widget
  tests without layout exceptions. These captures use test fonts. They do not
  establish final text quality or replace a full device review.
- The iPhone machine editor and thinking sheet were inspected in the simulator.
  Desktop machine-editor light/dark renders were inspected for spacing. A final
  check in the running Mac app was blocked by the screen lock.

## Rules for the next change

Use `AppColors` for UI colors, `AppShapes` for component corners, and the existing
shared controls. Keep desktop pointer controls compact. Keep mobile touch targets
large enough. Check both light and dark modes. Keep keyboard focus visible.
Do not stack a settings dialog inside another settings dialog.


## Mobile follow-up — 6 September 2026

- Replace the session drawer with a Back button to the home session list.
- Keep the mobile session header to the title, Back, and actions. Session
  information and pinned messages remain available from the actions menu.
- Put Effort inside the model picker for existing and new mobile sessions.
  Keep it above the scrollable model list. Use one-line descriptions.
- Reuse one mobile model picker. Keep desktop model and effort controls.
- Give mobile session rows clearer titles and move favorite actions into menus.
  Use native bottom navigation and a separate New session action.
- Increase mobile settings label sizes and make settings rows tappable.

Flutter analysis and all 394 tests passed, including a 30-model list in both
themes.
Both native development builds passed. The updated iPhone and Mac apps were
opened. The inspected Mac session showed its transcript; the inspected iPhone
session had no transcript content, so its message layout could not be checked
with that live session.

## Page consistency and loading follow-up

- Align trailing action menus with their trigger instead of placing them to
  its left. Verify the alignment with mobile and desktop control sizes.
- Remove unsupported usage entries and their count. Keep usage errors visible.
- Use plain card surfaces across management pages. Keep explicit status borders.
- Reduce badges and repeated machine metadata in usage cards.
- Replace all skeleton layouts with the existing shared loading indicator.
  Keep cached content during refresh. Remove unused skeleton widgets.

Flutter analysis and all 396 tests passed. The final menu constraint fix also
passed the three menu checks. Both native builds passed. The Usage page was
inspected in the iPhone simulator.

## First-load indicator correction

Page loading now shows the native spinner and its label together on the first
frame. Only background refresh keeps the delayed indicator. The first-frame
check passes in light and dark modes.

## Phone comparison follow-up

The first mobile picker still looked like a form beside the supplied Claude
reference. It used too much height, a prominent search field, and a clipped
card bottom. Selection also changed the description color.

The shared mobile picker now uses a shorter inset sheet, a circular close
control, search on demand, neutral descriptions, and a scroll area clipped
inside a rounded card. The default-model action sits below the choices.
The New session summary no longer repeats model and permission defaults;
broad-permission warnings remain visible.

Analysis and all 397 tests passed before the final spacing adjustment. The
46 focused capability checks passed after it, including both themes and
search with a keyboard inset.

Both native builds passed. The final picker was inspected in the iPhone
simulator with the real model catalog and app fonts.


## Theme ownership audit — 6 September 2026

The sweep covered every Dart source under `apps/mobile/lib`, including the
browser and inspector pages, all file/media viewers, terminal, desktop shell,
mobile sheets, onboarding, notifications, and the Linux development harness.
The initial inventory included 163 font-size settings, 86 direct font weights,
49 numeric corner-radius calls, 439 inset calls, and 210 numeric icon-size sites.
These counts include repeated styles and uses that already followed a token.

The foundation needed corrections before migration:

- Material cards and Mesh cards used different default surfaces and borders.
  Standard cards now use the elevated fill without an automatic border.
- Input states did not share a complete shape contract. Normal, focus, disabled,
  error, and focused-error states now use the same 12 px control radius.
  Inputs use the muted fill and retain readable hints and visible focus.
- Switches and icon buttons could retain their active appearance when disabled.
  The theme now resolves disabled colors. Switch thumbs have readable contrast
  against the selected track in every palette.
- Material surface roles now use the app palette instead of generated container
  colors. Slider and expansion-tile styles come from the global theme.

Screen changes use shared type, spacing, icon, corner, emphasis, and motion
roles. Near-duplicate values were consolidated instead of adding a constant for
every old literal. Default button and input style overrides were removed.
Semantic action variants, searchable fields, sheet controls, and action menus
are defined in `theme/app_control_styles.dart`.

Message/link styles moved to `theme/message_text_styles.dart`. Pill, status,
and surface mappings moved to `theme/app_status_styles.dart`. Terminal and
syntax palettes moved to `theme/app_code_theme.dart`. Media keeps fixed black
backgrounds and light controls through `AppMediaColors`; scrims use the shared
overlay theme. Notification accents now use the default theme palette.

`python3 scripts/check_flutter_theme.py` scans all 134 Dart files. It rejects
local colors, button/menu/input/shadow recipes, literal font sizes and weights,
font families, opacity, spacing, radii, strokes, and icon geometry. The guard
has checks for multiline and conditional expressions, comments, and strings.
CI runs analysis, the theme guard, and tests in that order.

Intentional local values: responsive dimensions and viewport geometry, media
aspect ratios, data/coordinate values, IO/debounce timers, transparent surfaces
that let an outer component own the paint, and semantic selection of theme
colors. These are behavior or layout, not alternative visual themes. The Astro
marketing/docs site has its own CSS theme and was not migrated into Flutter.

Validation: final Flutter analysis passed; source guard passed; all 398 Flutter
tests passed. Theme state and contrast tests cover all six palettes in both
modes. Final iOS simulator and macOS dev builds passed. Native visual checks
covered the iPhone session list, focused model search, dark Appearance page,
and the Mac conversation shell. Simulator color mode was restored to System.
No physical-device check was performed for this audit.

Visual evidence is saved in the task visualization directory:
`sidemesh-theme-home.png`, `sidemesh-theme-search-light.png`, and
`sidemesh-theme-appearance-dark.png`.


## Page layout and feedback review — 6 September 2026

This pass reviewed the source of all 42 Dart files in `lib/src/screens`,
including screen parts and inspector adapters. It also checked shared search,
sheet, empty-state, loader, and snackbar widgets. This is source coverage;
it does not mean every page was opened on every device.

| Area | Findings and changes |
| --- | --- |
| Session search, mobile sheet and desktop inspector | Removed the repeated heading, instructions, gray inner panel, zero count, and large empty illustration. Search results appear after a query. The mobile sheet now updates when the transcript changes. Loading, failure with Retry, empty conversation, and no matches have distinct states. Snippets show matching metadata when the preview does not contain the query. |
| Home, Inbox, Machines, Usage | Fixed old host labels, shortened repeated empty-state text, and made the empty usage heading specific. Session search now has an animated loading indicator. Existing card and row layouts remain. |
| Desktop shell and welcome view | Search uses the shared theme. Desktop search is 32 points high at normal text size, with 13-point text. Mobile retains touch sizing. Removed two first-machine buttons with the same action, corrected their labels, and removed the stretched icon background. Shortened the session welcome text. |
| New session and session controls | Profile and model search fields use the shared search style. Removed sheet descriptions that repeat the visible options. Kept explanations of profiles, access, permissions, and inherited settings. |
| Resources, pins, and agents | Removed the resources inner background and duplicate empty-state implementation. Empty resources no longer show zero counts for each filter. Filtered empty headings now name the missing type. Pinned messages have a specific heading. Agent errors use one shared empty state with a Retry action. |
| Session details, Git, diff, attachments | Removed sheet descriptions that repeat their headings or visible controls. Kept access and approval explanations. |
| Files, workspace browser, archive, structured data, tables | Removed repeated file-preview instructions and empty-file text. Kept parse errors, file-size limits, raw-view actions, and file boundaries. |
| Image, audio, video, PDF and preview panes | Reused the shared compact empty state. Added visible progress to image fetch placeholders. Kept playback controls, media backgrounds, and load errors. |
| Browser, network, browser tabs, terminal and their inspector/window adapters | Network search uses the shared search style. Removed the repeated request-detail introduction. Kept viewport behavior explanations, terminal controls, connection state, and error recovery. |
| Settings, appearance, onboarding, pairing | Reviewed headings, rows, loading state, and descriptions. Existing permission, setup, update, and data-deletion explanations remain. Shared sheet, search, and empty-state fixes apply where used. |
| Snackbars across the app | The overlay now reads `SnackBarThemeData` for its surface, text, shape, and actions. Removed its bold text and separate border recipe. Notices appear near the top, clear of composer controls. Kept queue and dismissal behavior, added live-region semantics, and kept actions available when accessible navigation is active. Removed redundant model-selection notices and duplicate first-load error notices. |

Shared sheets now paint behind the home indicator. A missing description does
not leave an empty gap. Compact empty states use a plain icon and can scroll
in a small pane. Search styles live in `theme/app_control_styles.dart`;
snackbar styles live in the Material theme. No dependency was added.

Validation covers search refresh and retry, matching metadata, filters and
clear, a 320-point phone with a keyboard and larger text, desktop input height
before and after typing, and snackbar theme, keyboard space, action lifetime,
and dismissal. Native visual checks sampled iPhone search, results with the
keyboard in light and dark modes, a dark-mode notice, desktop search, and
the welcome view. Light-mode notices were checked in widget tests. Physical-device, Android, Linux, and web visual checks were not run.


Final checks for this pass: Flutter analysis passed, the theme guard passed
for 134 Dart files, and all 403 Flutter tests passed. The iOS simulator and
macOS development builds passed. Generated deployment-target and CocoaPods
changes were removed from the source diff.

## Claude desktop interaction review — 6 September 2026

This review used the running Claude desktop app. It covered search, sidebar
filters, new-session controls, model choices, session actions, settings, and
side panels. It did not change account settings, send a prompt, or change a
model. The original conversation and panel layout were restored. Mobile
comparisons use the screenshots supplied by the user, not a live phone review.
Chat text and artifact content are not evidence of product behavior.

| Observed behavior | Application to Sidemesh |
| --- | --- |
| A small sidebar Search action opens a separate palette. Blank input shows recent work. Queries show matches and short excerpts. Arrow keys change selection, and Escape returns to the conversation. | Keep navigation small. Give search room only when the user opens it. Preserve the current conversation and keyboard focus. At the time of this review, Sidemesh had a smaller sidebar field. The implementation below adds this palette flow. |
| Sidebar filters show the current group, sort, and filter values in one menu. Further choices open beside that menu. | Put list controls together. Avoid permanent filter controls when they are not needed. |
| New session uses the conversation input location. Machine environment, recent folders, branch, and worktree choices sit near it. | Keep one clear start action. Reuse valid choices. Show setup detail when a choice needs to change. Keep machine identity and access policy clear where they affect the action. |
| Desktop model selection is a small menu with primary choices, selected state, and further models in a submenu. | Separate a quick choice from detailed configuration. Keep mobile effort inside model selection, as already requested. |
| The conversation header exposes common panel actions. Other session operations are grouped in an overflow menu. | Show common actions first. Move secondary session information and commands behind one consistent entry point. Keep required approvals visible. |
| General settings use section headings and plain rows, with each control beside its label. Explanations remain for settings with consequences. | Use one settings layout. Remove repeated instructions and decorative containers. Retain security, consent, and data-loss explanations. |
| Side panels share small headers with close and expand controls. The empty changes panel uses one short sentence. | Give file, resource, search, and preview panels the same basic structure. Empty views should explain the state or offer the next action. |
| Opening another side panel can leave the conversation very narrow. | Do not copy the full split-panel system. Keep a readable conversation width and use one active auxiliary panel at smaller widths. |

The next UX pass should trace complete user tasks: find and resume work, start
a session, read and reply, handle an approval or error, inspect an output,
and manage a machine. For each task, check visible choices, repeated facts,
required steps, return navigation, and recovery. Shared theme tests do not
prove that these tasks are simple. This review does not claim that the full
Sidemesh UX redesign is complete.


## UX implementation — 6 September 2026

Completed this pass using the existing theme and data paths. No dependency was
added. These changes address the task flows reviewed above.

- Desktop session search opens from the header or Command-F. It shows recent
  sessions, then query matches. Arrow keys select a row; Enter opens it; Escape
  closes search. The conversation stays mounted. Search uses RecentPane and
  its existing cache, provider search, loading, and failure states.
- The desktop session header combines the title and machine/folder context.
  Secondary data remains in session details and menus. Required approvals and
  active work controls remain available.
- New-session machine and folder choices sit above the input on both layouts.
  Folder selection opens directly. Draft text survives folder changes, and
  sending still requires a valid folder. Discard and access protections remain.
  The folder picker has one path row, a parent action, and a Use folder action.
- Narrow desktop windows show the inspector over the page. Opening it does not
  reduce the conversation width. Escape, Close, and the outside area dismiss
  it. Wide windows retain the existing resizable columns.
- Machine details put recent sessions before maintenance tools. Refresh keeps
  existing content visible. Initial connection failure has a Retry action.
- Usage refresh has a small activity indicator. Missing usage data no longer
  appears as an indeterminate progress bar. Repeated header data was removed.
- Existing settings categories and shared panel controls were reused. The
  prior source review of all 42 screen files remains the coverage record.

Validation: Flutter analysis passed, the theme guard passed for 134 Dart files,
and all 407 Flutter tests passed. Added checks cover search keyboard navigation
in light and dark modes, narrow-window inspector dismissal and width, and draft
retention during direct folder selection. Final iOS simulator and macOS dev
builds passed. Generated platform and CocoaPods changes were removed afterward.

Native checks covered the desktop search palette and new-session flow, plus
mobile new-session and folder views. The final mobile new-session view was
checked in light and dark modes. Simulator appearance was restored to light;
the app still follows System. No prompt was sent. Physical-device, Android,
Linux, and web visual checks were not run. This is a completed UX pass, not a
claim that every possible state on every platform has been inspected.

Saved images: `sidemesh-ux-new-mobile-light.png`,
`sidemesh-ux-new-mobile-dark.png`, and `sidemesh-ux-folder-mobile-dark.png` in
the task visualization directory.


## Detail dialogs and third pane — 6 September 2026

- Git details now uses a bounded column and the shared plain detail rows.
  Folder and repository paths appear separately only when they differ. Values
  are selectable. Ordinary file changes use neutral text. Refresh sits in the
  title row and updates the open dialog. A full-height route removes the old
  bottom-sheet limit that could hide diff controls and changed files.
- Shared sheets are centered at desktop widths. Mobile sheets keep their
  bottom placement. Session details no longer repeats status, source, machine,
  and Git data in both badges and rows. Runtime details use the same rows;
  context, usage, and compaction data remain available under their sections.
- Session controls uses compact model, mode, and effort choices. Its footer
  stays visible while the body scrolls. In the inspector, the selected access
  mode and explanation remain visible; expanding it shows all choices.
  Disabled-mode explanations and confirmation handling remain in place.
- Reviewed all inspector adapters: agents, browser preview and tabs, files,
  pins, resources, search, and terminal. The shared header now has a minimum
  height instead of a fixed height. File refresh and Back use themed keyboard
  controls. Existing list, search, media, and terminal views remain in use.
- A native launch check found a pre-existing call to an optional macOS launch
  callback with no superclass implementation. The call now checks whether the
  superclass implements it. The launch exception no longer appears.

Validation: Flutter analysis and the 134-file theme guard pass. All 409 tests
pass. Tests check Git layout and refresh in both modes, mode selection and
saving, and visible Apply controls while access options expand in a narrow
pane. iOS simulator and macOS development builds pass. Native iPhone checks
cover session controls in both modes and Git refresh. Simulator appearance
was restored to light. No setting was applied during native inspection.

The final Mac build is running, but its saved-machine load is waiting for
keychain access. Computer Use cannot open macOS security dialogs. Final native
Mac visual verification remains pending that system prompt; desktop widget
checks pass. This limit does not affect the iPhone simulator checks.


## Remaining UX gaps and settings placement — 6 September 2026

- Desktop session settings now open in a compact dialog. Model and effort stay
  at the composer. Reset and Apply preserve those separate reply settings.
  The settings form fits short content and keeps actions visible for long content.
  The former compact model dialog now inherits the theme background and shape.
- Saved-machine loading no longer presents an empty fleet. A slow read explains
  the secure-storage wait. Failed reads offer Retry and preserve stored settings.
  Overlapping reads are blocked. No keychain permissions were changed.
- Consecutive identical provider notices share one message and an occurrence
  count. Source and code remain under Details. Messages use normal text weight.
  Notices separated by other transcript entries keep their positions.
- Advanced new-session model, profile, and effort settings use compact fields.
  Removed the old card badges. Loading and retry actions remain available.
- Pinned details use a short title, one metadata line, header actions, selectable
  content, and a content-sized sheet. Opening a pin closes the list first.
- Resources uses one filter and refresh row. Each category count appears once.
  Native checks covered the loaded media count and an empty links filter.

Validation: Flutter analysis and the 134-file theme guard pass. All 414 tests
pass. The new checks cover desktop settings and preserved reply choices in both
modes, saved-machine waiting and retry, notice grouping, and pinned-sheet route
replacement in both modes. Final macOS and iOS simulator dev builds pass.
Generated platform project and CocoaPods changes were removed afterward.

Native checks covered desktop settings in both modes, expanded access options,
the composer model picker, and consecutive notice grouping. Saved machines now
load in the Mac app; the earlier keychain wait did not recur. Simulator checks
covered resource filtering and pinned detail layout in both modes. A native pin
check exposed the sheet navigation race; the final regression tests confirm its
fix. The temporary pin was removed. Mac appearance was restored to System and
simulator appearance to light. Final builds are running. No session settings or
messages were submitted. Physical-device and other-platform visual checks remain
outside this pass.

## Final cleanup and draft status — 6 September 2026

The seven remaining UX findings now have source changes and regression checks.
See [the remaining UX audit](remaining-ux-audit-2026-09-06.md#implementation-results)
for the changes, validation results, and open native checks. Flutter analysis,
the theme guard, and all 428 standard Flutter tests passed after the PR #357
rebase. Both host storage tests passed in the separate Data Protection run;
the profile validation test passed too. The Apple development builds passed
before this rebase and were not rerun. The branch retains PR #355 and its
session recovery changes.

An earlier Mac relaunch returned unauthorized errors for saved machines. The
user fixed startup Keychain access separately in PR #357. This branch now
includes that fix through a rebase onto main at `86f91d5`. Final native checks
and the simulator version check remain open; the final pass is not fully
verified on native devices.
