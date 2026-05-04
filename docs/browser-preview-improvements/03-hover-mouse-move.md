# 03 — Hover / mouseMoved for Desktop Previews

**Severity**: 🟡 P1  
**Effort**: Small  
**Files touched**: `apps/mobile/lib/src/screens/browser_preview_screen.dart`, `src/browser-preview.ts`

---

## Problem Statement

Moving the pointer over the preview image without tapping does nothing. No `mouseMoved` events are dispatched to Chromium. This means:

- CSS `:hover` tooltips and dropdown menus never appear.
- Cursor-sensitive UI (e.g. image editors, design tools, canvas apps) is unusable.
- The user has no visual feedback about what will be clicked before tapping.

### Exact Code Locations

`BrowserPreviewPane` uses a `GestureDetector` that only handles discrete gestures (`onTapUp`, `onVerticalDragUpdate`, `onHorizontalDragUpdate`). There is no continuous pointer tracking callback.

---

## Flutter Pointer-Event Mechanics

Flutter offers two ways to receive raw pointer movement:

1. **Listener widget** with `onPointerHover` — fires when the pointer moves without buttons pressed. Works on desktop and web targets; on mobile it fires when a stylus hovers.
2. **MouseRegion** with `onHover` — higher-level, provides local position, but is suppressed on most mobile builds.

For Sidemesh, a `Listener` wrapping the preview body is the most robust choice because it works across all platforms (mobile with finger drag, desktop with mouse move, and tablet with stylus).

---

## Proposed Solution

Wrap the preview body in a `Listener` and throttle hover events to avoid flooding the WebSocket.

### Flutter side

```dart
Listener(
  onPointerHover: (event) => _sendHover(event.localPosition, size),
  onPointerMove: (event) {
    if (_isDragging) _sendHover(event.localPosition, size);
  },
  child: GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTapDown: ...,
    onTapUp: ...,
    onPanUpdate: ...,
    child: ...
  ),
)
```

Add a throttle to avoid > 60 hover messages per second:

```dart
DateTime? _lastHoverSent;

void _sendHover(Offset localPosition, Size size) {
  final now = DateTime.now();
  if (_lastHoverSent != null && now.difference(_lastHoverSent!).inMilliseconds < 16) {
    return; // ~60 fps cap
  }
  final point = _mapPoint(localPosition, size);
  if (point == null) return;
  _send({'type': 'hover', 'x': point.dx, 'y': point.dy});
  _lastHoverSent = now;
}
```

### Backend side

Add `hover` to `applyInput` in `browser-preview.ts`:

```ts
if (type === "hover") {
  const point = normalizedPoint(message, preview);
  await cdp.send("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x: point.x,
    y: point.y,
  }, sessionId);
  return;
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| High-frequency hover events saturate the WebSocket | Throttle to 60 Hz; skip if `bufferedAmount > threshold`. |
| Mobile finger hover is meaningless | `onPointerHover` only fires for styluses/mice on mobile. Normal finger drags go through `onPanUpdate`, which is already handled. |
| Backend ignores hover for mobile viewports | Optional: gate `hover` handling behind `preview.width >= 700`. |

---

## Acceptance Criteria

- [ ] Moving the mouse over a desktop preview shows hover CSS states (e.g. button highlights, tooltips).
- [ ] Hover messages are throttled and do not degrade streaming frame rate.
- [ ] No regression on tap or scroll behavior.
