# Remaining UX audit — 6 September 2026

This records the audit of the working tree and running development apps before
the final UI cleanup. The findings below describe that earlier state. The user
permits removal of low-value or duplicate menu items. Implementation results
and open checks are recorded at the end.

## Scope and evidence

- Source inventory: 42 files under `screens/`, including inspector surfaces.
- Theme guard: passed across 134 Dart files. This checks its defined rules;
  it does not prove that every layout is good or that every style is covered.
- Live desktop checks: session actions, panel menu, file list, README preview,
  media resources, browser preview, and the empty Agents panel.
- Live iPhone checks: conversation and session actions in light and dark modes.
- The remaining preview formats and populated agent states were checked in
  source only. They still need device checks with suitable data.
- Saved screenshots below were captured and opened during this audit. They are
  local review files, not release assets.

## Findings, in inspection order

### 1. File preview controls compete with the file — medium

The 328-pixel desktop panel has a Files header and another header with Back,
filename, language badge, path, Edit, Copy, Preview, and Refresh. The path is
almost unreadable. Markdown opens as source in a padded gray surface, which
leaves less room for the document.

Use one compact file header. Keep Back, the filename, and the main view control
visible. Put secondary actions in the existing menu. Consider rendered Markdown
as the reading view, with source still available.

Source: `inspector/inspector_file_browser.dart:240` and
`file_viewer_pane.dart:808`.

![Desktop file preview](/tmp/sidemesh-remaining-audit/files.png)

### 2. Tool rows still dominate the conversation — medium

The same capture shows many two-line `Tool / exec` and `Tool / js` rows. These
labels do not explain what happened. A provider deprecation message also appears
in the main transcript. The earlier duplicate-notice fix groups only adjacent
matches; it does not remove this remaining reading burden.

Use a meaningful tool title when one is available. Compact repeated routine
activity. Put informational provider diagnostics in details; keep errors,
approvals, and actionable warnings visible.

Source: `session_screen_timeline.dart:3146–3202`.

### 3. Resource names do not help users find an image — medium

This session has 87 media entries. Visible cards repeat `Tool output image` and
`Tool Output`. The filter only separates media, links, and files. It cannot
distinguish these images. The thumbnails are useful, but the repeated captions
add height without useful information.

Use existing meaningful attachment names where possible. For unnamed images,
show a short time or source context, and reduce repeated captions. Do not add a
search field until the entries have useful searchable text.

Source: `inspector/inspector_resources.dart:519` and `src/resources.ts:221`.

![Desktop resources](/tmp/sidemesh-remaining-audit/resources.png)

### 4. Mobile session actions are too long — medium

The menu contains 17 actions in this session. Rename and Archive are below the
first view. It mixes tools, navigation, settings, and recovery actions. This is
present in both light and dark modes.

Remove New session from this menu; Home already provides it. Move Reload and
Restart agent to a secondary troubleshooting group. Keep Rename, Archive,
Search, and necessary session settings easy to reach. Keep Files, Browser,
Terminal, and Agents available as workspace tools. Do not remove useful
capabilities just to shorten the list.

Source: `session_screen.dart:6420–6570`.

![Mobile actions, light](/tmp/sidemesh-remaining-audit/mobile-actions.png)

![Mobile actions, dark](/tmp/sidemesh-remaining-audit/mobile-actions-dark.png)

### 5. Menu check marks have conflicting meanings — medium

Git receives a check mark when files changed. Session controls receives one
when settings are custom. Other actions use it to mean that their panel is
open. A check mark therefore does not identify one clear state.

Reserve checks for selection. Show a small change count or status text for Git,
and remove the custom-settings check from the menu. Also rename the desktop
entry to Session settings to match the dialog. Its description still mentions
model and thinking although those controls now live below the composer.

Source: `session_screen.dart:6460`, `:6485`, and `:7188`.

### 6. Agent status is reduced too far — medium, source-confirmed

The summary calculates `done = total - active`. Row accessibility labels also
call every non-active run `done`. The server can return idle, closed, and errored
states. These states are not equivalent. Waiting for approval is counted as
active and receives the same green indicator as running.

Use the existing status value. Distinguish needs-input, error, running, and
stopped states. This is an accuracy fix, not a new design system.

Source: `agent_runs_screen.dart:157–216`, `models.dart:948`,
`src/server.ts:4939` and `:5363`. The live session had no agent runs, so these
populated states were not reproduced on a device in this audit.

### 7. Some preview states retain the old treatment — low, source-confirmed

Audio and video still use standalone progress indicators. Their error widgets
have no local Retry action. PDF uses the shared loader and has Retry. ZIP
preview has a large summary card with up to five badges before its contents;
table preview also starts with a badge row.

Reuse the existing loader and error actions. Reduce ZIP/table summaries to a
short text row while preserving limits and format warnings. Confirm the result
with real audio, video, ZIP, and table files in both modes.

Source: `audio_viewer_pane.dart:331`, `video_viewer_pane.dart:740`,
`pdf_viewer_pane.dart:213`, `archive_preview_pane.dart:241–310`, and
`tabular_file_preview.dart:249`.

## Checks that did not establish a defect

The mobile browser callback sets docked-preview state before closing the tab
list; it does not push a new preview route. It is not the same route-order bug
as the earlier pinned-message issue. The resources callback deserves a device
check with a file/link entry, but this audit did not reproduce a route failure.

## Suggested order

First simplify the action menu and correct its state labels. Then fix the file
header and agent status labels. Next reduce transcript and resource noise.
Finish with the remaining preview loading, error, and summary states.

## Implementation results

- File previews use a compact filename header and an action menu for Edit,
  Copy, and Refresh. Markdown opens in reading view; source remains available.
- Routine tool rows omit the generic Tool label and use an available action
  title. Identical informational provider notices share a collapsed row even
  when other entries separate them. Warnings and errors remain visible.
- Resource captions use an existing name, filename, or timestamp. Repeated
  Tool Output labels were removed. Failed image loads have a Retry action.
- Session menus no longer repeat New session or use checks for unrelated
  states. Workspace tools and troubleshooting actions are grouped. Model and
  effort remain at the composer on both desktop and mobile; session settings
  retain the other controls.
- Agent rows and details use the reported status. Idle, error, stopped, and
  waiting states are no longer called done or shown as running.
- Audio, video, PDF, images, conversation attachments, and resource previews
  use shared loading and error components. Failed media can be retried.
  Archive and table summaries use compact text while retaining format and
  size warnings. Browser connection loading uses the shared indicator.

## Validation and open checks

Flutter analysis passed, the theme guard passed across 134 Dart files, and all
428 Flutter tests passed after updating the branch to include PR #357. The
standard run skips the Data Protection test; both host storage tests passed
in the separate Data Protection run. The profile validation test also passed.
Tests
include agent status, image retry, audio/video
initialization failure and retry, menus, and notice grouping. Relevant widget
checks cover light and dark modes. macOS development and iOS simulator builds
passed before the PR #357 rebase; they were not rerun for this rebase. Local
validation used Flutter 3.47.1; CI uses the pinned Flutter 3.44.7.

Final native verification is incomplete. An earlier Mac relaunch showed
unauthorized errors for saved machines. The user fixed startup Keychain access
separately in PR #357, now included through the rebase onto main at `86f91d5`.
That fix uses fresh Data Protection storage for signed releases and requires
machines to be paired again once. Ad-hoc development builds retain the regular
Keychain. No additional credential-storage changes are part of this UI diff.

The simulator also appeared to show an older interface after installation;
the installed-version check remains open. Physical-device, Android, Linux,
and web visual checks were not completed for this final cleanup.
