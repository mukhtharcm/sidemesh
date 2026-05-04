# 01 — Gesture Recognizer Collision & Tap Fidelity

**Severity**: 🔴 P0  
**Effort**: Small  
**Files touched**: `apps/mobile/lib/src/screens/browser_preview_screen.dart`

---

## Problem Statement

Flutter's `GestureDetector` in `BrowserPreviewPane` registers conflicting recognizers, causing:

1. **Diagonal scroll loss**: When a user drags diagonally, only the dominant axis (vertical or horizontal) receives events because the two drag recognizers compete in the gesture arena.
2. **Missing press-and-hold**: There is no `onTapDown` handler. CDP only receives a synthesized `mousePressed` immediately followed by `mouseReleased` on `onTapUp`. Web pages that rely on `:active` states, drag handles, or long-press context menus do not work.

### Exact Code Locations

```dart
// apps/mobile/lib/src/screens/browser_preview_screen.dart:598–610
GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTapUp: (details) => _sendTap(details, size),
  onVerticalDragUpdate: (details) => _sendScroll(details, size),
  onHorizontalDragUpdate: (details) => _sendScroll(details, size),
  child: ...
)
```

```dart
// _sendTap only sends a complete click on finger lift.
void _sendTap(TapUpDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({'type': 'tap', 'x': point.dx, 'y': point.dy});
}
```

On the backend (`src/browser-preview.ts:560–590`), a `tap` message is translated to:

```ts
await cdp.send("Input.dispatchMouseEvent", { type: "mousePressed", ... });
await cdp.send("Input.dispatchMouseEvent", { type: "mouseReleased", ... });
```

There is **no delay** between pressed and released, so the browser sees an instantaneous click.

---

## Flutter Gesture Arena Mechanics (Research)

In Flutter, a `GestureDetector` with both `onVerticalDragUpdate` and `onHorizontalDragUpdate` creates two `VerticalDragGestureRecognizer` and `HorizontalDragGestureRecognizer` instances. They enter the gesture arena simultaneously. The arena resolves when:

- One recognizer declares victory (the pointer moves predominantly in that axis).
- The other recognizer is rejected and its callbacks are **never** called.

Diagonal drags therefore lose one axis entirely. The fix is to use a **pan recognizer** (`PanGestureRecognizer`) which accepts movement in any direction, or to allow **simultaneous recognition** via `RawGestureDetector`.

Reference: [Flutter GestureDetector docs](https://api.flutter.dev/flutter/widgets/GestureDetector-class.html) and the `GestureArenaManager` behavior.

---

## Proposed Solution

### Phase A — Replace drag with pan

Replace the two drag callbacks with a single `onPanUpdate`:

```dart
GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTapDown: (details) => _sendTapDown(details, size),
  onTapUp: (details) => _sendTapUp(details, size),
  onPanUpdate: (details) => _sendScroll(details, size),
  child: ...
)
```

Update `_sendScroll` to consume `DragUpdateDetails` from the pan (the API shape is identical):

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

### Phase B — Add tap-down / tap-up split

Add a new WebSocket message type `tapDown`:

```dart
void _sendTapDown(TapDownDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({'type': 'tapDown', 'x': point.dx, 'y': point.dy});
}

void _sendTapUp(TapUpDetails details, Size size) {
  final point = _mapPoint(details.localPosition, size);
  if (point == null) return;
  _send({'type': 'tapUp', 'x': point.dx, 'y': point.dy});
}
```

On the backend, handle `tapDown` and `tapUp` separately:

```ts
if (type === "tapDown") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: point.x,
    y: point.y,
    button: "left",
    buttons: 1,
    clickCount: 1,
  }, sessionId);
  return;
}

if (type === "tapUp") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: point.x,
    y: point.y,
    button: "left",
    buttons: 0,
    clickCount: 1,
  }, sessionId);
  return;
}
```

**Backward compatibility**: Keep the legacy `tap` type handling on the backend so older Flutter clients still work. The new split is additive only.

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Splitting tapDown/tapUp may cause stuck "mouse pressed" if the app loses focus before tapUp fires | Add an AppLifecycleState listener that sends a synthetic `tapUp` (or explicit `mouseReleased`) when the app goes to background while a tap is in progress. |
| Pan gesture might swallow tap events | Flutter `GestureDetector` defaults allow taps to coexist with pan if the pan does not compete with short-duration pointers. Verify with `gestureSettings` or explicit `GestureRecognizerFactoryWithHandlers`. |
| Coordinate drift during long press | `_mapPoint` already clamps to `[0,1]`; the issue is unchanged. |

---

## Acceptance Criteria

- [ ] Diagonal dragging on a map or scrollable grid scrolls both axes.
- [ ] Holding a finger on a button shows the browser's `:active` CSS state.
- [ ] Drag handles (e.g. sliders, range inputs) work correctly.
- [ ] Legacy `tap` messages still produce a full click on the backend.
