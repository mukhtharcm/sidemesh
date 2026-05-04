# 02 — Touch-Event Support vs. mouseWheel Scrolling

**Severity**: 🔴 P0  
**Effort**: Medium  
**Files touched**: `src/browser-preview.ts`, `apps/mobile/lib/src/screens/browser_preview_screen.dart`

---

## Problem Statement

The current scroll implementation dispatches CDP `Input.dispatchMouseEvent` with `type: "mouseWheel"`. Many modern mobile-first web applications listen exclusively for `touchstart`, `touchmove`, and `touchend` (via `addEventListener` or frameworks like React Touch) and **ignore wheel events entirely**. On such sites, scrolling inside the remote browser preview is silently broken.

### Exact Code Locations

Flutter side (`browser_preview_screen.dart`):

```dart
void _sendScroll(DragUpdateDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({
    'type': 'scroll',
    'x': point.dx,
    'y': point.dy,
    'deltaY': -details.delta.dy * 3,
    'deltaX': -details.delta.dx * 3,
  });
}
```

Backend side (`browser-preview.ts:570–585`):

```ts
if (type === "scroll") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseWheel",
    x: point.x,
    y: point.y,
    deltaX: numberValue(message.deltaX, 0),
    deltaY: numberValue(message.deltaY, 0),
  }, sessionId);
  return;
}
```

The `* 3` multiplier on the Flutter side is an arbitrary fudge factor to make wheel scrolling feel faster. CDP `mouseWheel` expects deltas in **CSS pixels**, but the multiplier does not adapt to viewport DPI or device scale.

---

## CDP Research: `Input.dispatchTouchEvent`

Chromium DevTools Protocol provides `Input.dispatchTouchEvent`, which accepts:

```ts
{
  type: "touchStart" | "touchMove" | "touchEnd" | "touchCancel",
  touchPoints: Array<{
    x: number,
    y: number,
    radiusX?: number,
    radiusY?: number,
    rotationAngle?: number,
    force?: number,
    id?: number
  }>,
  modifiers?: number,
  timestamp?: number
}
```

Key findings:

- `touchStart` initiates a touch sequence. The browser fires `touchstart` DOM events.
- `touchMove` fires `touchmove` DOM events.
- `touchEnd` fires `touchend` and, if the touch did not move significantly, synthesizes a `click` event automatically.
- Chromium's mobile viewport emulation (`Emulation.setDeviceMetricsOverride` with `mobile: true`) already hints to the page that it is a touch device, but this alone does not cause untouchable pages to work unless actual touch events are injected.

Reference: [CDP Input domain](https://chromedevtools.github.io/devtools-protocol/tot/Input/)

---

## Proposed Solution

### Phase A — Add touch-event path for mobile-sized viewports

When the preview width is < 700 (the same threshold used for `mobile: true` in `setViewport`), send touch events instead of wheel events. For desktop-sized viewports, keep `mouseWheel`.

**New message types** (Flutter → Daemon):

| Message | When |
|---------|------|
| `touchStart` | `onPanStart` / `onTapDown` |
| `touchMove` | `onPanUpdate` |
| `touchEnd` | `onPanEnd` / `onTapUp` |
| `touchCancel` | App goes to background, socket closes, or pointer is stolen |

**Flutter changes**:

```dart
void _sendTouchStart(DragStartDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({
    'type': 'touchStart',
    'x': point.dx,
    'y': point.dy,
    'id': 0,
  });
}

void _sendTouchMove(DragUpdateDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({
    'type': 'touchMove',
    'x': point.dx,
    'y': point.dy,
    'id': 0,
  });
}

void _sendTouchEnd(DragEndDetails? details, Size size) {
  // Use last known position if DragEndDetails is null
  _send({'type': 'touchEnd', 'id': 0});
}
```

**Backend changes** (`applyInput` in `browser-preview.ts`):

```ts
if (type === "touchStart") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchStart",
    touchPoints: [{ x: point.x, y: point.y, id: numberValue(message.id, 0) }],
  }, sessionId);
  return;
}

if (type === "touchMove") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchMove",
    touchPoints: [{ x: point.x, y: point.y, id: numberValue(message.id, 0) }],
  }, sessionId);
  return;
}

if (type === "touchEnd") {
  await cdp.send("Input.dispatchTouchEvent", {
    type: "touchEnd",
    touchPoints: [],
  }, sessionId);
  return;
}
```

### Phase B — Unified "pointer" abstraction (optional)

Instead of maintaining parallel `mouseWheel` and `touch*` paths, introduce a `pointer` message type that the backend translates based on viewport mode:

```dart
_send({
  'type': 'pointer',
  'kind': 'scroll',
  'x': point.dx,
  'y': point.dy,
  'deltaY': -details.delta.dy,
  'deltaX': -details.delta.dx,
});
```

Backend decides whether to emit `mouseWheel` or `touchMove` depending on `preview.width < 700`. This keeps the Flutter code simpler but requires a larger backend refactor.

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Switching to touch may break desktop pages that rely on hover/wheel | Keep the desktop branch (`width >= 700`) on `mouseWheel`. |
| Multi-touch is not supported | Document limitation; single-touch covers 95% of use cases. |
| `touchEnd` without coordinates may confuse some Chromium builds | Always send an empty `touchPoints` array for `touchEnd`; Chromium expects this. |
| Coordinate normalization drifts during fast swipes | Same risk as today; no new risk introduced. |

---

## Acceptance Criteria

- [ ] A mobile-sized preview (< 700 px width) can scroll a site that uses `touchmove` listeners (e.g. many React/Vue mobile UIs).
- [ ] A desktop-sized preview (>= 700 px width) still scrolls via `mouseWheel` so desktop sites with hover-scrollbars work.
- [ ] The `* 3` delta multiplier is removed or made configurable; scrolling feels native.
- [ ] No regression on tap-to-click behavior.
