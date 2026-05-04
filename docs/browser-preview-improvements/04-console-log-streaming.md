# 04 — Console Log Streaming from Remote Browser

**Severity**: 🟡 P1  
**Effort**: Medium  
**Files touched**: `src/browser-preview.ts`, `apps/mobile/lib/src/screens/browser_preview_screen.dart`, `apps/mobile/lib/src/models.dart`

---

## Problem Statement

When a user is previewing a local web app (e.g. a Vite/React dev server) through Sidemesh, runtime JavaScript errors and `console.log` output are invisible. The user must open a separate terminal and look at the dev server logs, or run the app locally. This breaks the "remote workspace in your pocket" value proposition.

---

## CDP Research

### `Runtime.consoleAPICalled`

Fired whenever `console.log`, `console.warn`, `console.error`, etc. are called.

```ts
{
  type: "log" | "debug" | "info" | "error" | "warning" | "dir" | ...,
  args: Array<RemoteObject>,
  timestamp: number,
  stackTrace?: StackTrace,
  ...
}
```

Requires `Runtime.enable` (already called in `startPreview`).

### `Runtime.exceptionThrown`

Fired for uncaught JS exceptions.

```ts
{
  timestamp: number,
  exceptionDetails: {
    text: string,
    lineNumber: number,
    columnNumber: number,
    scriptId?: string,
    url?: string,
    stackTrace?: StackTrace,
    exception?: RemoteObject
  }
}
```

### `Log.entryAdded`

Fired for browser-internal log entries (network errors, CSP violations, deprecation warnings). Requires `Log.enable`.

```ts
{
  entry: {
    source: "javascript" | "network" | ...,
    level: "verbose" | "info" | "warning" | "error",
    text: string,
    timestamp: number,
    url?: string,
    lineNumber?: number,
    ...
  }
}
```

---

## Proposed Solution

### Phase A — Backend: subscribe and forward

In `startPreview` (`browser-preview.ts:355`), after `Runtime.enable`, add:

```ts
await cdp.send("Runtime.enable", {}, sessionId);
await cdp.send("Log.enable", {}, sessionId);
```

Register listeners in `registerBrowserNavigationHandlers` (or a new helper):

```ts
preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Runtime.consoleAPICalled", (params) => {
    this.broadcast(preview, {
      type: "console",
      level: stringValue(params.type),
      args: params.args,
      timestamp: numberValue(params.timestamp, Date.now()),
    });
  }),
);

preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Runtime.exceptionThrown", (params) => {
    const details = objectValue(params.exceptionDetails);
    this.broadcast(preview, {
      type: "exception",
      text: stringValue(details?.text),
      url: stringValue(details?.url),
      lineNumber: numberValue(details?.lineNumber, 0),
      columnNumber: numberValue(details?.columnNumber, 0),
      timestamp: Date.now(),
    });
  }),
);

preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Log.entryAdded", (params) => {
    const entry = objectValue(params.entry);
    this.broadcast(preview, {
      type: "log",
      level: stringValue(entry?.level),
      source: stringValue(entry?.source),
      text: stringValue(entry?.text),
      url: stringValue(entry?.url),
      lineNumber: numberValue(entry?.lineNumber, 0),
      timestamp: numberValue(entry?.timestamp, Date.now()),
    });
  }),
);
```

**Rate-limiting concern**: A page with a tight `requestAnimationFrame` loop that logs every frame could spam the WebSocket. Add a simple ring buffer on the backend:

```ts
private readonly consoleBuffer: Array<Record<string, unknown>> = [];
private readonly maxConsoleBuffer = 256;

// In the listener, push to buffer instead of immediate broadcast.
// Broadcast on a 500 ms timer or when buffer reaches 32 items.
```

### Phase B — Flutter: console overlay UI

Add a collapsible bottom panel inside `BrowserPreviewPane` (or a modal sheet). Reuse the existing `_InputRail` pattern.

```dart
class _ConsolePanel extends StatelessWidget {
  const _ConsolePanel({required this.entries, required this.onClear});
  final List<BrowserConsoleEntry> entries;
  final VoidCallback onClear;
  ...
}
```

Store entries in `_BrowserPreviewPaneState`:

```dart
final List<BrowserConsoleEntry> _consoleEntries = [];
final int _maxConsoleEntries = 200;

void _handleConsole(dynamic payload) {
  if (payload is! Map) return;
  final type = payload['type'];
  if (type != 'console' && type != 'exception' && type != 'log') return;
  setState(() {
    _consoleEntries.add(BrowserConsoleEntry.fromJson(payload));
    if (_consoleEntries.length > _maxConsoleEntries) {
      _consoleEntries.removeAt(0);
    }
  });
}
```

Add a toggle button in `_PreviewHeader` or `_BrowserControlStrip`:

```dart
_BrowserBarButton(
  icon: Icons.terminal_rounded,
  label: 'Console',
  onTap: _toggleConsole,
)
```

### Phase C — Model update

Add `BrowserConsoleEntry` to `apps/mobile/lib/src/models.dart`:

```dart
class BrowserConsoleEntry {
  const BrowserConsoleEntry({
    required this.type,
    required this.level,
    required this.text,
    this.url,
    this.lineNumber,
    this.columnNumber,
    required this.timestamp,
  });

  final String type; // 'console' | 'exception' | 'log'
  final String level; // 'log' | 'error' | 'warning' | ...
  final String text;
  final String? url;
  final int? lineNumber;
  final int? columnNumber;
  final int timestamp;
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Console spam DoS's the WebSocket | Backend ring buffer + throttled broadcast; old clients ignore unknown `type` messages. |
| RemoteObject serialization is huge | Only forward `args` if the total JSON < 4 KB; otherwise truncate and send `text: "[Object]"`. |
| `Log.enable` adds host CPU overhead | Make console streaming opt-in via a UI toggle; do not enable `Log` until the user opens the console panel. |

---

## Acceptance Criteria

- [ ] `console.log` in the remote page appears in the Flutter console panel within 1 second.
- [ ] `console.error` and uncaught exceptions are highlighted in red with stack trace line numbers.
- [ ] The console panel is scrollable and can be cleared.
- [ ] Enabling the console panel does not degrade frame streaming noticeably.
- [ ] Older Flutter clients ignore `console` / `exception` / `log` messages gracefully.
