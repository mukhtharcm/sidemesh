# 09 — Input Pipeline Gaps

**Severity**: 🔴 P0  
**Effort**: Small  
**Files touched**: `src/browser-preview.ts`, `apps/mobile/lib/src/screens/browser_preview_screen.dart`

---

## Problem Statement

Beyond the gesture collision and touch-event issues covered in [01](01-gesture-recognizers.md) and [02](02-touch-event-support.md), the input pipeline is missing several common interactions:

1. **Right-click / secondary tap**: No way to open browser context menus.
2. **Double-tap**: No `onDoubleTap` handler; double-tap-to-zoom does not work.
3. **Long-press**: No `onLongPress` handler; long-press context menus and text selection do not work.
4. **Scroll inertia**: The current `mouseWheel` approach (and even a future touch approach) does not send inertia/fling velocity. The page stops scrolling the instant the finger lifts.
5. **Text selection**: Without `mouseMoved` + drag, the user cannot click-and-drag to select text.

---

## Detailed Gap Analysis

### Right-click / Secondary Tap

**Flutter**: Add `onSecondaryTapUp` (desktop mouse) and `onLongPress` (mobile) to the `GestureDetector`.

**Backend**: Add `type: "secondaryTap"`:

```ts
if (type === "secondaryTap") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed",
    x: point.x,
    y: point.y,
    button: "right",
    buttons: 2,
    clickCount: 1,
  }, sessionId);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased",
    x: point.x,
    y: point.y,
    button: "right",
    buttons: 0,
    clickCount: 1,
  }, sessionId);
}
```

### Double-tap

**Flutter**: Use `GestureDetector.onDoubleTap`:

```dart
GestureDetector(
  onDoubleTap: () => _sendDoubleTap(details, size),
  ...
)
```

**Backend**: CDP `Input.dispatchMouseEvent` supports `clickCount: 2`. Send two rapid press/release pairs with `clickCount: 2` on the second pair, or use `Input.dispatchMouseEvent` with `type: "mousePressed"` twice. Chromium's double-click detection interval is OS-dependent (~500 ms).

```ts
if (type === "doubleTap") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x: point.x, y: point.y, button: "left", buttons: 1, clickCount: 1,
  }, sessionId);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: point.x, y: point.y, button: "left", buttons: 0, clickCount: 1,
  }, sessionId);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x: point.x, y: point.y, button: "left", buttons: 1, clickCount: 2,
  }, sessionId);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: point.x, y: point.y, button: "left", buttons: 0, clickCount: 2,
  }, sessionId);
}
```

### Long-press

**Flutter**: `GestureDetector.onLongPress`:

```dart
onLongPress: () => _sendLongPress(details, size),
```

**Backend**: For mouse emulation, a long press is just a `mousePressed` held for ~500 ms before `mouseReleased`. For touch emulation, send `touchStart`, wait, then `touchEnd`. The delay should match platform conventions (Android ~400 ms, iOS ~500 ms).

```ts
if (type === "longPress") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mousePressed", x: point.x, y: point.y, button: "left", buttons: 1, clickCount: 1,
  }, sessionId);
  await new Promise(r => setTimeout(r, 500));
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseReleased", x: point.x, y: point.y, button: "left", buttons: 0, clickCount: 1,
  }, sessionId);
}
```

### Scroll inertia / fling

**Flutter**: `GestureDetector.onPanEnd` provides `DragEndDetails.velocity`.

```dart
void _sendFling(DragEndDetails details, Size size) {
  final velocity = details.velocity.pixelsPerSecond;
  _send({
    'type': 'fling',
    'velocityX': velocity.dx,
    'velocityY': velocity.dy,
  });
}
```

**Backend**: CDP `Input.dispatchMouseEvent` with `type: "mouseWheel"` does not natively support inertia. The pragmatic approach is to send a sequence of decaying wheel events:

```ts
if (type === "fling") {
  const vx = numberValue(message.velocityX, 0);
  const vy = numberValue(message.velocityY, 0);
  let remainingVx = vx * 0.3;
  let remainingVy = vy * 0.3;
  while (Math.abs(remainingVx) > 10 || Math.abs(remainingVy) > 10) {
    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: preview.width / 2,
      y: preview.height / 2,
      deltaX: remainingVx * 0.016,
      deltaY: remainingVy * 0.016,
    }, sessionId);
    remainingVx *= 0.9;
    remainingVy *= 0.9;
    await new Promise(r => setTimeout(r, 16));
  }
}
```

This is a **coarse simulation**. A better long-term fix is to use `Input.synthesizePinchGesture` or `Input.synthesizeScrollGesture` (CDP experimental) which accept velocity vectors directly.

### Text selection (click-and-drag)

**Prerequisite**: This requires the hover/mouseMoved support from [03-hover-mouse-move.md](03-hover-mouse-move.md) and the tap-down/tap-up split from [01-gesture-recognizers.md](01-gesture-recognizers.md).

**Flutter**: Track drag state:

```dart
bool _isDragging = false;

onPanStart: (details) {
  _isDragging = true;
  _sendTapDown(...); // mousePressed
},
onPanUpdate: (details) {
  if (_isDragging) _sendHover(...); // mouseMoved
},
onPanEnd: (details) {
  _isDragging = false;
  _sendTapUp(...); // mouseReleased
},
```

**Backend**: The existing `hover` + `tapDown` + `tapUp` handlers are sufficient once implemented.

---

## Proposed Implementation Order

1. **Secondary tap** — smallest change, high impact for desktop users.
2. **Double-tap** — needed for mobile web zoom gestures.
3. **Long-press** — unlocks context menus and text selection on mobile.
4. **Fling inertia** — requires the most tuning; schedule after touch-event support is in place.
5. **Text selection** — depends on 01 + 03; schedule last.

---

## Acceptance Criteria

- [ ] Right-click opens the browser's context menu in desktop previews.
- [ ] Double-tap triggers zoom on mobile pages that support it.
- [ ] Long-press shows context menus on mobile.
- [ ] Lifting the finger after a fast swipe continues scrolling with simulated inertia.
- [ ] Click-and-drag selects text when hover + tap-down are implemented.
