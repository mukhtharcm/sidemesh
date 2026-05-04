# 06 — Migrate from Polling to `Page.startScreencast`

**Severity**: 🟢 P2  
**Effort**: Large  
**Files touched**: `src/browser-preview.ts`

---

## Problem Statement

The backend polls `Page.captureScreenshot` on a fixed interval (`frameIntervalMs`, default 900 ms). This design has several downsides:

1. **Latency during interaction**: When the user taps or scrolls, the visual feedback is delayed by up to 900 ms because the next frame is not captured until the timer fires.
2. **Wasted CPU on static pages**: If the page has not visually changed, Chromium still encodes and transmits a full JPEG every 900 ms.
3. **No backpressure from client readiness**: The timer fires regardless of whether the Flutter client has finished decoding the previous frame.

### Exact Code Locations

`captureAndBroadcast` (`browser-preview.ts:650–690`):

```ts
private async captureAndBroadcast(preview) {
  if (preview.capturingFrame) return;
  preview.capturingFrame = true;
  try {
    const response = await cdp.send("Page.captureScreenshot", {
      format: "jpeg",
      quality: this.quality,
      fromSurface: true,
      optimizeForSpeed: true,
    }, sessionId);
    // ... broadcast
  } finally {
    preview.capturingFrame = false;
  }
}
```

`startFrameLoop` sets a `setInterval` that calls `captureAndBroadcast` unconditionally.

---

## CDP Research: `Page.startScreencast`

Chromium provides a purpose-built screencast API:

```ts
cdp.send("Page.startScreencast", {
  format: "jpeg",
  quality: 55,
  maxWidth?: number,
  maxHeight?: number,
  everyNthFrame?: number,
});
```

Chromium then pushes `Page.screencastFrame` events:

```ts
{
  data: string,           // base64 image
  metadata: {
    offsetTop: number,
    pageScaleFactor: number,
    deviceWidth: number,
    deviceHeight: number,
    scrollOffsetX: number,
    scrollOffsetY: number,
    timestamp: number,
  },
  sessionId: number,
}
```

To acknowledge receipt and allow the next frame, the client must call:

```ts
cdp.send("Page.screencastFrameAck", { sessionId });
```

Key advantages over polling:

- **Push-based**: Frames arrive as soon as Chromium renders them (subject to `maxWidth`/`maxHeight`/`everyNthFrame`).
- **Backpressure**: If the client does not ack, Chromium pauses new frames automatically.
- **Metadata**: `timestamp` and `scrollOffset` enable smoother UI and adaptive behavior.
- **Efficiency**: Chromium can skip identical frames internally when no repaint occurred.

Reference: [CDP Page domain](https://chromedevtools.github.io/devtools-protocol/tot/Page/)

---

## Proposed Solution

### Phase A — Replace timer with screencast events

1. Remove `startFrameLoop` and `stopFrameLoop`.
2. After the preview reaches `running` status, call `Page.startScreencast`.
3. Listen to `Page.screencastFrame` on the CDP session.
4. On each frame, broadcast to clients and ack Chromium.

```ts
// In startPreview or attach completion:
await cdp.send("Page.startScreencast", {
  format: "jpeg",
  quality: this.quality,
  maxWidth: preview.width,
  maxHeight: preview.height,
}, sessionId);

preview.cleanupHandlers.push(
  cdp.onSessionEvent(sessionId, "Page.screencastFrame", (params) => {
    const data = stringValue(params.data);
    const metadata = objectValue(params.metadata);
    preview.lastFrameAt = Date.now();
    preview.updatedAt = preview.lastFrameAt;
    preview.lastError = null;

    const framePayload = {
      type: "frame",
      seq: preview.nextFrameSeq++,
      mimeType: "image/jpeg",
      width: preview.width,
      height: preview.height,
      timestamp: preview.lastFrameAt,
      scrollOffsetX: numberValue(metadata?.scrollOffsetX, 0),
      scrollOffsetY: numberValue(metadata?.scrollOffsetY, 0),
      data,
    };
    preview.lastFramePayload = framePayload;
    this.broadcast(preview, framePayload);

    // Ack to unblock next frame
    void cdp.send("Page.screencastFrameAck", {
      sessionId: numberValue(params.sessionId, 0),
    }, sessionId);
  }),
);
```

### Phase B — Stop screencast on client disconnect

When the last client leaves, call `Page.stopScreencast` to free Chromium resources:

```ts
private stopFrameLoop(preview) {
  // legacy clearInterval removed
  preview.cdp?.send("Page.stopScreencast", {}, preview.sessionIdCdp).catch(() => {});
}
```

### Phase C — Resume on reconnect

When a new client attaches after a period with no viewers, the preview record is still alive but screencast is stopped. In `attach`, restart screencast if no screencast listener is active:

```ts
if (!preview.hasScreencastListener) {
  await cdp.send("Page.startScreencast", ...);
}
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Older Chromium builds lack `startScreencast` | Fallback to polling if the CDP command returns an error. Feature-detect, not version-detect. |
| `screencastFrameAck` must be sent or Chromium stalls | Always ack, even if broadcast fails. Use `void` so acks are fire-and-forget. |
| Frame metadata format changed across Chromium versions | Only read `scrollOffsetX/Y` and `timestamp`; ignore unknown fields. |
| Multiple clients cause duplicate acks | The current backend sends one broadcast to all clients. Only ack once per screencast frame, regardless of client count. |

---

## Acceptance Criteria

- [ ] Frame latency during interaction is < 300 ms (vs. current 900 ms).
- [ ] CPU usage on the host drops measurably when the remote page is static.
- [ ] The fallback polling path still works if `startScreencast` is unsupported.
- [ ] Frame sequence numbers (`seq`) remain monotonic across reconnects.
