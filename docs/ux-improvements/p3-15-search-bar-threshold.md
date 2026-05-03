# P3-15 — Search bar visible even with very few sessions

## Problem

The search bar is always rendered at the top of the home screen
regardless of how many sessions exist.  With 2–3 sessions, a full-width
bordered search input + view-mode button dominates the visual space
and makes the screen feel sparse and under-populated.

Search only adds value when there are enough entries to need filtering.
Below a threshold, the bar is visual noise.

## Affected files

- `apps/mobile/lib/src/screens/home_screen.dart` — `_HomeStickyHeader`,
  `_HomeSearchField`

## Implementation plan

### Step 1 — Define a threshold

Show the search bar only when the total session count across all enabled
hosts exceeds a threshold, e.g. **10 sessions**.

```dart
static const int _searchThreshold = 10;
```

Track total session count in `_SidemeshHomeScreenState` using the
`RecentSessionsStore` entry count.

### Step 2 — Add `searchVisible` parameter to `_HomeStickyHeader`

```dart
class _HomeStickyHeader extends StatelessWidget {
  const _HomeStickyHeader({
    ...
    required this.searchVisible,
  });

  final bool searchVisible;
  ...
}
```

### Step 3 — Conditionally render the search field

```dart
if (searchVisible)
  _HomeSearchField(
    controller: searchController,
    hintText: 'Search ${tab.title.toLowerCase()}',
    viewMode: viewMode,
    onViewModeChanged: onViewModeChanged,
  ),
```

When the search bar is hidden, the search icon in the AppBar-equivalent
header area can optionally be shown as a small `MeshIconButton` for
users who want to search despite few sessions.

### Step 4 — Always show search on Hosts tab

The Hosts tab has its own search for filtering host names.  Even with
few hosts, search is useful when the user has many disabled ones.
Keep the search bar visible on the Hosts tab regardless of threshold.

### Step 5 — Smooth appearance

When session count crosses the threshold, animate the search bar in
with a `AnimatedSwitcher` or `AnimatedSize` so it doesn't jarringly
appear.

## Acceptance criteria

- With < 10 total sessions, the search bar is hidden.
- With ≥ 10 total sessions, the search bar appears (with animation).
- The Hosts tab always shows the search bar.
- Users can still access search below the threshold via a small icon.
- The view-mode switcher (flat/byCwd/byHost) is only shown when the
  search bar is visible.
