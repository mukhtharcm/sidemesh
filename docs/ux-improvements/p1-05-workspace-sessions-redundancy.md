# P1-05 — Workspaces and Sessions show the same data twice

## Problem

The host detail screen has two list sections stacked vertically:

1. **Workspaces** — groups sessions by `cwd`, shows folder name + session
   count, tap to start a new session there.
2. **Sessions** — shows every session card with `cwd` visible.

The same working directories and same sessions appear in both sections.
A user scrolling down sees their work duplicated with no clear reason
why both views exist.

The workspaces section's real job — "tap to start a new session here" —
is not stated anywhere.  It looks like a second sessions list.

## Affected files

- `apps/mobile/lib/src/screens/host_detail_screen.dart`

## Implementation plan

### Option A — Reframe the Workspaces section as a "Quick launch" row

Change the Workspaces section from a full card-per-workspace list into a
**horizontal scrolling chip row** above the Sessions section.  Each chip
shows the folder basename and session count.  The section is labelled
"Quick launch".

```
Quick launch
[⌘ sidemesh  3] [⌘ myapp  1] [⌘ scripts  7]  ←  scrollable
```

This makes the purpose ("tap to launch") obvious, takes much less
vertical space, and clearly separates it from the detailed sessions
list below.

### Step 1 — Replace `_WorkspaceCard` list with `_WorkspaceLaunchRow`

```dart
class _WorkspaceLaunchRow extends StatelessWidget {
  const _WorkspaceLaunchRow({
    required this.workspaces,
    required this.onTap,
  });
  ...
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: workspaces.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, i) => _WorkspaceLaunchChip(
          workspace: workspaces[i],
          onTap: () => onTap(workspaces[i]),
        ),
      ),
    );
  }
}
```

Each chip:
```dart
InkWell(
  borderRadius: AppShapes.pill,
  onTap: onTap,
  child: Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(
      color: colors.surfaceMuted,
      borderRadius: AppShapes.pill,
      border: Border.all(color: colors.border),
    ),
    child: Row(children: [
      Icon(Icons.folder_rounded, size: 14, color: colors.accent),
      SizedBox(width: 6),
      Text(workspace.label, style: ...),
      if (workspace.sessionCount > 1) ...[
        SizedBox(width: 6),
        _CountBadge(workspace.sessionCount),
      ],
    ]),
  ),
)
```

### Step 2 — Update the section header

Change `_SectionHeader` title from "Workspaces" to "Quick launch" and
subtitle to "Tap a folder to start a new session there."

### Step 3 — Remove the old `_WorkspaceCard` class

Delete `_WorkspaceCard` — no longer needed.

### Step 4 — Sessions section: suppress cwd when it matches session context

Since workspaces are now a separate compact row, the sessions section
can keep its cwd.  No change needed here.

## Acceptance criteria

- The host detail page no longer shows the same data twice.
- The quick-launch row clearly communicates "tap to start a session here."
- The sessions list shows the full session cards without duplication.
- If there is only one workspace, no quick-launch row is shown (not
  useful for a single directory).
