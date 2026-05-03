# P1-06 — Host label is redundant on host-detail session cards

## Problem

Every `SessionRowCard` in the host detail sessions list shows:

```
🖥 MacBook Pro · /path/to/project   3m ago
```

The user is already on the "MacBook Pro" host detail page.  The host
label appears in the AppBar/embedded header AND in every single session
card — 10 times in a typical list.  This is pure redundancy that wastes
the metadata row's horizontal space (forcing the `cwd` path to
truncate earlier).

## Affected files

- `apps/mobile/lib/src/screens/host_detail_screen.dart` — session list
  rendering
- `apps/mobile/lib/src/widgets/session_row_card.dart` — `SessionRowCard`

## Implementation plan

### Step 1 — Add `showHost` parameter to `SessionRowCard`

```dart
class SessionRowCard extends StatelessWidget {
  const SessionRowCard({
    ...
    this.showHost = true,   // ← new, defaults to true
  });

  final bool showHost;
  ...
```

### Step 2 — Gate the host icon + label on `showHost`

In `_buildBody` (non-dense variant), wrap the host icon + label + badges
row segment in `if (showHost)`:

```dart
Row(
  children: [
    if (showHost) ...[
      Icon(Icons.dns_rounded, size: 13, ...),
      const SizedBox(width: 4),
      Flexible(flex: 0, child: Text(host.label, ...)),
    ],
    if (session.provider != null && showHost) ...[
      const SizedBox(width: 8),
      AgentProviderBadge(providerKind: session.provider),
    ],
    if (session.isSubAgent && showHost) ...[
      const SizedBox(width: 6),
      const _SubAgentBadge(),
    ],
    const SizedBox(width: 8),
    Expanded(child: Text(session.cwd, ...)),  // cwd always shown
    ...
  ],
),
```

When `showHost == false`, the metadata row shows only `cwd` + relative
time, giving the path much more room to breathe.

### Step 3 — Pass `showHost: false` from host detail

In `host_detail_screen.dart` where `SessionRowCard` is constructed:

```dart
SessionRowCard(
  host: widget.host,
  session: session,
  favorite: ...,
  onTap: ...,
  onToggleFavorite: ...,
  showHost: false,   // ← we're already on this host's page
),
```

### Step 4 — Provider badge still shown even when host is hidden

The provider badge (`AgentProviderBadge`) is useful even without the
host label.  Show it inline next to the cwd:

```dart
Row(
  children: [
    Expanded(child: Text(session.cwd, ...)),
    if (!showHost && session.provider != null) ...[
      const SizedBox(width: 6),
      AgentProviderBadge(providerKind: session.provider, compact: true),
    ],
    const SizedBox(width: 8),
    _timeLabel,
  ],
),
```

## Acceptance criteria

- Host-detail session cards no longer show the host label.
- The `cwd` path gets more horizontal space and truncates less often.
- The provider badge is still visible (compact form, inline with cwd).
- `SessionRowCard` on the Recent tab is unaffected (default
  `showHost: true`).
