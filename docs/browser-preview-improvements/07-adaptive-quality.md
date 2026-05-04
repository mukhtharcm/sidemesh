# 07 — Adaptive Quality, WebP, and Frame-Rate

**Severity**: 🟢 P2  
**Effort**: Medium  
**Files touched**: `src/browser-preview.ts`, `apps/mobile/lib/src/screens/browser_preview_screen.dart`

---

## Problem Statement

1. **JPEG only**: `Page.captureScreenshot` is called with `format: "jpeg"`. Modern Chromium supports `webp`, which produces significantly smaller files at the same visual quality.
2. **Static quality**: The `quality` setting (default 55) is fixed per preview. During fast interaction, lower quality is acceptable for lower latency; when the page is static, higher quality looks better.
3. **Static frame rate**: The timer is fixed at `frameIntervalMs` (default 900 ms). There is no burst mode during user interaction.

---

## Research: Screenshot Formats in Chromium

CDP `Page.captureScreenshot` supports:

| Format | Chromium support | Typical size vs JPEG |
|--------|-----------------|---------------------|
| `png` | Universal | ~3–5× larger |
| `jpeg` | Universal | Baseline |
| `webp` | Chrome 104+ | ~30–50% smaller at same quality |

`Page.startScreencast` (see [06-screencast-migration.md](06-screencast-migration.md)) also supports `webp`.

For Sidemesh, **WebP is the clear win** for mobile bandwidth. The Flutter `Image.memory` widget supports WebP via the platform codec (Android/iOS both have WebP decoders).

---

## Proposed Solution

### Phase A — Detect WebP support and prefer it

When launching Chrome, do a quick capability probe after CDP connection:

```ts
let supportsWebp = false;
try {
  await cdp.send("Page.captureScreenshot", {
    format: "webp",
    quality: 55,
    fromSurface: true,
  }, sessionId);
  supportsWebp = true;
} catch {
  supportsWebp = false;
}
```

Store `supportsWebp` on `BrowserPreviewRecord` and use it for all subsequent captures.

### Phase B — Adaptive quality ladder

Maintain a per-preview quality state:

```ts
interface AdaptiveQualityState {
  currentQuality: number;
  targetQuality: number;
  lastInteractionAt: number;
  interactionBurstMs: number;
}
```

Rules:

- On any input event (`tap`, `scroll`, `key`), set `lastInteractionAt = Date.now()` and `targetQuality = Math.max(30, this.quality - 15)`.
- In the frame loop, if `Date.now() - lastInteractionAt < 2_000`, use `targetQuality`.
- Otherwise, ramp back to `this.quality` over 3–5 frames.

This creates an "interaction burst" effect: while the user is scrolling, frames are lower quality but arrive faster; when idle, frames are crisp.

### Phase C — Adaptive frame-rate (only if still polling)

If the screencast migration ([06](06-screencast-migration.md)) is not yet implemented, adapt the timer interval:

```ts
private computeFrameInterval(preview: BrowserPreviewRecord): number {
  const sinceInteraction = Date.now() - preview.lastInteractionAt;
  if (sinceInteraction < 2_000) {
    return Math.max(250, this.frameIntervalMs / 3); // burst to ~300 ms
  }
  return this.frameIntervalMs;
}
```

If screencast *is* implemented, the adaptive frame-rate comes for free from Chromium's push model; the quality adaptation still applies.

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| WebP probe adds ~50 ms to preview startup | Do it inside the existing `startPreview` flow; the overhead is negligible compared to Chrome launch. |
| Quality bouncing is visually distracting | Ramp quality gradually (step by 3 per frame) rather than switching instantly. |
| Flutter `Image.memory` may not decode WebP on very old Android | Fallback to JPEG at decode time: if `Image.memory` throws on WebP bytes, switch the preview back to JPEG and broadcast an update. |

---

## Acceptance Criteria

- [ ] Hosts with modern Chromium use WebP; older hosts fall back to JPEG.
- [ ] Average frame payload size is reduced by >= 25% on WebP hosts.
- [ ] During active scrolling, frame latency improves (interval ≤ 300 ms if polling; or subjective smoothness if screencast).
- [ ] Static frames return to the configured quality within 5 seconds of last interaction.
