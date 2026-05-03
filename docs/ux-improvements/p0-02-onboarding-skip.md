# P0-02 — Skip during onboarding strands new users

## Problem

The onboarding screen has a "Skip" button in the top-right corner on
every page.  Tapping it on any of the first 4 pages calls `_complete()`
which marks onboarding done and pushes the home screen.

The home screen's Recent tab shows "No sessions yet / Add a host first"
with no actionable CTA — the FAB on that tab only appears on the Hosts
tab.  The user is left on a blank screen with no path forward.

Even users who reach page 5 (Connect) and tap "I'll do this later" hit
the same dead end.

## Affected files

- `apps/mobile/lib/src/screens/onboarding_screen.dart` — `_skip()`,
  `_complete()`
- `apps/mobile/lib/src/screens/home_screen.dart` — Recent pane empty
  state, HostsPane

## Implementation plan

### Step 1 — Change Skip to jump to page 5, not exit

On pages 0–3, rename "Skip" to "Skip intro" and navigate to page 4
(the Connect page) instead of calling `_complete()`.

```dart
void _skipIntro() {
  _pageController.animateToPage(
    _pageCount - 1,
    duration: const Duration(milliseconds: 400),
    curve: Curves.easeInOutCubic,
  );
}
```

On page 4 (Connect), show "I'll do this later" as a text button that
calls the real `_complete()`.

### Step 2 — Add an "Add host" nudge on the home screen empty state

In `RecentPane`, when `hasSavedHosts == false`, add a `FilledButton`
below the `MeshEmptyState` that calls `onAddHost` (already wired up to
`_showHostEditor` in `SidemeshHomeScreen`).  The empty state already
passes `hasSavedHosts` as a parameter.

```dart
if (!hasSavedHosts) ...[
  const SizedBox(height: AppSpacing.lg),
  FilledButton.icon(
    onPressed: onAddHost,
    icon: const Icon(Icons.add_link_rounded),
    label: const Text('Add your first host'),
  ),
],
```

### Step 3 — Pass `onAddHost` to `RecentPane`

`RecentPane` currently doesn't have an `onAddHost` callback.  Add:
```dart
final VoidCallback? onAddHost;
```
and wire it from `SidemeshHomeScreen`.

### Step 4 — Show "Add host" FAB on all tabs when no hosts exist

Currently the FAB only appears on the Hosts tab when
`_hosts.isNotEmpty`.  Change the condition so the FAB appears on ANY
tab when `_hosts.isEmpty` and tapping it opens the host editor.

## Acceptance criteria

- Tapping "Skip intro" on pages 0–3 lands on the Connect page, not
  home.
- Tapping "I'll do this later" on the Connect page → home screen shows
  an "Add your first host" button.
- New users always have a clear next action.
