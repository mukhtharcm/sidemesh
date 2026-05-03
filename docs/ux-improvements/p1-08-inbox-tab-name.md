# P1-08 — "Inbox" tab name doesn't match mental model

## Problem

The second bottom-nav tab is called "Inbox".  It contains:
1. **Pending approval actions** — the agent is waiting for the user to
   approve/reject a command or file change.
2. **Queued sends** — messages the user sent that couldn't be delivered.

"Inbox" is email vocabulary.  Users hunting for "the thing that needs
my attention" or "pending approvals" won't naturally look in "Inbox."
In user testing, "Approvals" or "Actions" are more immediately
understood for an agent control plane.

The badge count on this tab already reflects pending approvals, making
"Inbox" feel even more like a category mismatch.

## Affected files

- `apps/mobile/lib/src/screens/home_screen.dart` — `_tabs` definition,
  `_TabDef` entries
- `apps/mobile/lib/src/screens/desktop_shell.dart` — any references to
  the tab label

## Implementation plan

### Step 1 — Rename the tab

In `_SidemeshHomeScreenState._tabs`:

```dart
static const _tabs = [
  _TabDef(
    title: 'Recent',
    subtitle: 'Latest activity across the fleet',
    icon: Icons.schedule_rounded,
    selectedIcon: Icons.schedule_rounded,
  ),
  _TabDef(
    title: 'Actions',                                    // ← was 'Inbox'
    subtitle: 'Pending approvals and queued sends',      // ← updated
    icon: Icons.checklist_rounded,                       // ← new icon
    selectedIcon: Icons.checklist_rounded,
  ),
  _TabDef(
    title: 'Hosts',
    subtitle: 'Your mesh of agent nodes',
    icon: Icons.hub_rounded,
    selectedIcon: Icons.hub_rounded,
  ),
];
```

`Icons.checklist_rounded` or `Icons.task_alt_rounded` communicates
"things needing action" better than `Icons.all_inbox_rounded`.

### Step 2 — Update the InboxPane section headers

Inside `InboxPane`, there are two section headers that reference
"Inbox" indirectly via their content:

- Empty state when no hosts: `title: 'Inbox is empty'` → `'Nothing needs attention'`
- The "queued messages" section header already uses its own label, no change needed.

### Step 3 — Search hint text

`_HomeSearchField` builds `hintText: 'Search ${tab.title.toLowerCase()}'`
which becomes "Search actions" — fine.

### Step 4 — Desktop shell sidebar label

Search `desktop_shell.dart` for any hardcoded "Inbox" strings and
update them.

### Step 5 — Notification routing label (if any)

Check `local_notification_service.dart` and `live_activity_service.dart`
for any user-facing "Inbox" labels.

## Acceptance criteria

- Bottom nav shows "Actions" with a checklist icon.
- Empty state reads "Nothing needs attention."
- No user-facing string still says "Inbox."
- Functionality is completely unchanged.
