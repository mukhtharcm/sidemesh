# 05 — Page Load & JS Error State Indicators

**Severity**: 🟡 P1  
**Effort**: Small  
**Files touched**: `src/browser-preview.ts`, `apps/mobile/lib/src/screens/browser_preview_screen.dart`

---

## Problem Statement

When the user clicks **Reload** or navigates to a new URL, the preview shows the **last stale frame** until the next screenshot timer fires (up to 900 ms by default). There is no visual feedback that a navigation is in progress. If the page fails to load (e.g. 404, connection refused), the user sees the old page or a blank frame with no explanation.

### Exact Code Locations

Navigation in `browser-preview.ts:625–645`:

```ts
private async navigatePreviewToUrl(preview, url) {
  const result = await cdp.send("Page.navigate", { url }, sessionId);
  const errorText = stringValue(result.errorText);
  if (errorText) {
    throw new BrowserPreviewError(`Could not open browser URL: ${errorText}`, 502);
  }
  this.updatePreviewUrl(preview, url);
  await this.captureAndBroadcast(preview);
}
```

The method immediately returns after `Page.navigate` resolves. CDP `Page.navigate` resolves when the **navigation starts**, not when the page finishes loading. The frame loop may capture a white/loading screen or the old page depending on timing.

---

## CDP Research

### `Page.loadEventFired`

Fired when the whole page has loaded, including all dependent resources.

### `Page.domContentEventFired`

Fired when the DOM is ready (analogous to `DOMContentLoaded`).

### `Page.frameStartedLoading` / `Page.frameStoppedLoading`

Fired when a frame starts or stops loading. Useful for showing a spinner on the main frame.

---

## Proposed Solution

### Phase A — Backend: broadcast load lifecycle events

In `registerBrowserNavigationHandlers`, add:

```ts
preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Page.frameStartedLoading", (params) => {
    const frameId = stringValue(params.frameId);
    if (frameId !== preview.targetId) return; // only care about main frame
    this.broadcast(preview, { type: "loading", state: "started" });
  }),
);

preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Page.loadEventFired", () => {
    this.broadcast(preview, { type: "loading", state: "complete" });
  }),
);
```

Keep the existing `Page.frameNavigated` handler (it updates `preview.url`).

### Phase B — Flutter: visual loading state

Extend `_BrowserPreviewPaneState`:

```dart
bool _pageLoading = false;

void _handleLoading(Map frame) {
  final state = frame['state'];
  if (!mounted) return;
  setState(() {
    _pageLoading = state == 'started';
  });
}
```

In `_buildPreviewBody`, when `_pageLoading` is true and bytes are present, overlay a subtle indeterminate progress indicator:

```dart
Stack(
  children: [
    Image.memory(bytes, ...),
    if (_pageLoading)
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: LinearProgressIndicator(minHeight: 2),
      ),
  ],
)
```

### Phase C — Navigation error overlay

When `Page.navigate` returns an `errorText` (e.g. `net::ERR_CONNECTION_REFUSED`), the backend currently throws and broadcasts an `error` message. The Flutter side treats this as a transient capture error and keeps showing the last good frame.

Improve the error handling path:

**Backend** (`browser-preview.ts`):

```ts
if (errorText) {
  this.broadcast(preview, {
    type: "navError",
    url,
    error: errorText,
  });
  return;
}
```

**Flutter** (`browser_preview_screen.dart`):

```dart
if (type == 'navError') {
  final url = frame['url'] ?? '';
  final error = frame['error'] ?? '';
  setState(() {
    _status = 'Failed to load $url: $error';
  });
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Rapid navigation toggles loading state aggressively | Debounce the loading indicator: require 150 ms of `started` before showing the progress bar. |
| `loadEventFired` does not fire for SPAs using client-side routing | Also listen to `Page.frameNavigated` on the main frame; it fires for `history.pushState` navigation in many SPAs. |
| Older clients see `loading` messages as unknown types | Safe — old code ignores anything that is not `hello` / `ready` / `preview` / `frame` / `error` / `closed`. |

---

## Acceptance Criteria

- [ ] Tapping "Reload" shows a thin progress bar at the top of the preview within 200 ms.
- [ ] The progress bar disappears when the page finishes loading.
- [ ] A navigation failure (e.g. server down) shows a human-readable error message instead of the old frame.
- [ ] Client-side routing in SPAs (e.g. Next.js, React Router) also triggers the loading indicator.
