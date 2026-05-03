# P3-19 — Host management card needs a section header

## Problem

The `_HostManagementCard` (Restart provider / Restart daemon) was moved
to the bottom of the host detail screen's `ListView` in PR #130.  This
is the correct location for potentially destructive/technical actions.

However, there is no visual separator between the last session card and
the management card.  It appears immediately after the sessions list
with the same `AppSpacing.lg` gap — looking like just another session-
related item to a casual scroller.

Users who need it won't notice it; users who don't need it might
accidentally tap it.

## Affected files

- `apps/mobile/lib/src/screens/host_detail_screen.dart` —
  `_buildBody()` ListView, management card placement

## Implementation plan

### Step 1 — Add a `_SectionHeader` before the management card

In `_buildBody()`, before `_HostManagementCard`, insert:

```dart
const SizedBox(height: AppSpacing.lg),
_SectionHeader(
  icon: Icons.medical_services_rounded,
  title: 'Host management',
  subtitle: 'Restart the provider or daemon when stuck.',
),
const SizedBox(height: AppSpacing.sm),
_HostManagementCard(
  host: widget.host,
  api: widget.api,
  node: data.node,
),
```

The `_SectionHeader` widget is already defined in
`host_detail_screen.dart` (used for Workspaces and Sessions).

### Step 2 — Remove the duplicate title from `_HostManagementCard` itself

`_HostManagementCard.build` currently renders its own header row:
```dart
Row(children: [
  Icon(Icons.medical_services_rounded, ...),
  Text('Host management', ...),
]),
Divider(...)
```

Once the external `_SectionHeader` is in place, this internal header
is redundant.  Remove it to avoid double-labelling.

### Step 3 — Gate the section on capability + always show daemon restart

The section should always appear (daemon restart is always valid) but
the "Restart provider" row should still be capability-gated.

Remove the capability gate from the section's visibility — only the
individual row is gated.

## Acceptance criteria

- A "Host management" section header appears above the management card,
  using the same visual style as the Workspaces and Sessions headers.
- The management card no longer has its own internal title row.
- The section is visually separated from the sessions list above it.
- The card still shows on every host detail page.
