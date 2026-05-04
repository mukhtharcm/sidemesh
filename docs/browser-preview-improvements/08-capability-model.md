# 08 — Granular Browser-Preview Capability Model

**Severity**: 🟢 P2  
**Effort**: Small  
**Files touched**: `src/types.ts`, `src/server.ts`, `apps/mobile/lib/src/models.dart`, `apps/mobile/lib/src/screens/*.dart`

---

## Problem Statement

`HostCapabilities.workspace.browserPreview` is a single boolean. As we add console logs, network monitor, remote JS eval, or touch-event support, the daemon has no way to advertise which sub-features are available. The Flutter app must either show all UI (risking broken controls on older daemons) or gate everything behind the coarse boolean (hiding useful features).

---

## Current Code

`src/types.ts`:

```ts
export interface HostCapabilities {
  workspace: {
    filesystem: boolean;
    gitStatus: boolean;
    gitDiff: boolean;
    terminal: boolean;
    portForwarding: boolean;
    browserPreview: boolean;
  };
}
```

`apps/mobile/lib/src/models.dart`:

```dart
class HostCapabilities {
  ...
  final bool browserPreview;
}
```

---

## Proposed Solution

### Phase A — Extend the type (additive, backward-compatible)

Change `browserPreview` from `boolean` to an object with optional flags:

**Backend (`src/types.ts`)**:

```ts
export interface BrowserPreviewCapabilities {
  screenshots: boolean;
  consoleLogs?: boolean;
  networkMonitor?: boolean;
  remoteJsEval?: boolean;
  touchEvents?: boolean;
  hover?: boolean;
  screencast?: boolean; // Page.startScreencast available
}

export interface HostCapabilities {
  workspace: {
    ...
    browserPreview: boolean | BrowserPreviewCapabilities;
  };
}
```

For backward compatibility, serializing to JSON should keep the old boolean when all sub-flags are false/default. However, it's simpler to always emit the object:

```ts
browserPreview: {
  screenshots: true,
  consoleLogs: true,
  touchEvents: true,
  hover: true,
  screencast: false,
}
```

### Phase B — Flutter parsing (defensive)

```dart
class BrowserPreviewCapabilities {
  const BrowserPreviewCapabilities({
    required this.screenshots,
    this.consoleLogs = false,
    this.networkMonitor = false,
    this.remoteJsEval = false,
    this.touchEvents = false,
    this.hover = false,
    this.screencast = false,
  });

  final bool screenshots;
  final bool consoleLogs;
  final bool networkMonitor;
  final bool remoteJsEval;
  final bool touchEvents;
  final bool hover;
  final bool screencast;

  factory BrowserPreviewCapabilities.fromJson(dynamic json) {
    if (json is bool) {
      return BrowserPreviewCapabilities(screenshots: json);
    }
    if (json is Map) {
      final m = json.cast<String, dynamic>();
      return BrowserPreviewCapabilities(
        screenshots: m['screenshots'] == true,
        consoleLogs: m['consoleLogs'] == true,
        ...
      );
    }
    return const BrowserPreviewCapabilities(screenshots: false);
  }
}
```

### Phase C — UI gating

In `BrowserPreviewScreen` and `PortForwardScreen`, check the granular flags:

```dart
final caps = host.capabilities.browserPreviewCapabilities;
if (caps?.consoleLogs == true) {
  // show console toggle
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Older Flutter clients expect `browserPreview` to be a boolean | The Dart parser handles both `bool` and `Map`; test with `capability_ui_gates_test.dart`. |
| Older daemon backends send a boolean | The Dart `fromJson` coerces `true` → `screenshots: true, everythingElse: false`. |

---

## Acceptance Criteria

- [ ] New daemons advertise granular capabilities.
- [ ] New Flutter clients read granular capabilities and hide unsupported UI.
- [ ] Old Flutter clients + new daemon still show the preview (backward compatibility).
- [ ] New Flutter clients + old daemon still show the preview (backward compatibility).
