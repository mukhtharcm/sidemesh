# Browser Preview Streaming — Improvement Roadmap

> **Status**: Investigation complete, awaiting prioritization.
> **Scope**: Daemon backend (`src/browser-preview.ts`) + Flutter client (`apps/mobile/lib/src/screens/browser_preview_screen.dart`).
> **Goal**: Close QOL gaps in input fidelity, debugging visibility, and streaming efficiency.

---

## Summary of Findings

The browser preview feature streams a headless Chromium viewport to the Flutter app via CDP `Page.captureScreenshot`. After a full code walk-through, we identified **nine concrete improvement areas** across input propagation, DevTools integration, and streaming performance.

### Severity Legend

| Tag | Meaning |
|-----|---------|
| 🔴 **P0** | Breaks common user workflows today |
| 🟡 **P1** | Annoyance or missing capability with clear workaround |
| 🟢 **P2** | Nice-to-have; unlocks advanced use cases |

---

## The Nine Work Streams

| # | Topic | Severity | Effort | Files Touched |
|---|-------|----------|--------|---------------|
| 1 | [Gesture recognizer collision & tap fidelity](01-gesture-recognizers.md) | 🔴 P0 | Small | Flutter |
| 2 | [Touch-event support vs. mouseWheel scrolling](02-touch-event-support.md) | 🔴 P0 | Medium | Backend + Flutter |
| 3 | [Hover / mouseMoved for desktop previews](03-hover-mouse-move.md) | 🟡 P1 | Small | Flutter + Backend |
| 4 | [Console log streaming from remote browser](04-console-log-streaming.md) | 🟡 P1 | Medium | Backend + Flutter |
| 5 | [Page load & JS error state indicators](05-page-load-error-indicators.md) | 🟡 P1 | Small | Backend + Flutter |
| 6 | [Migrate from polling to `Page.startScreencast`](06-screencast-migration.md) | 🟢 P2 | Large | Backend |
| 7 | [Adaptive quality, WebP, and frame-rate](07-adaptive-quality.md) | 🟢 P2 | Medium | Backend |
| 8 | [Granular browser-preview capability model](08-capability-model.md) | 🟢 P2 | Small | Backend + Flutter |
| 9 | [Input pipeline gaps](09-input-pipeline-gaps.md) | 🔴 P0 | Small | Flutter + Backend |

---

## Cross-Cutting Concerns

### Testing Gap

There are **zero** CDP-interaction tests and zero Flutter browser-preview widget tests. Every change above should be accompanied by:

- **Backend**: A fake CDP harness that mocks `CdpConnection` so we can assert the exact JSON sent to Chromium (see `src/browser-preview.test.ts` for current test style).
- **Flutter**: Pump `BrowserPreviewPane` with a fake `WebSocketChannel` and assert outgoing messages.

### WebSocket Protocol Stability

All new features add message types to the viewer WebSocket. We must keep backward compatibility so older Flutter clients do not crash when receiving unknown `type` values. New message kinds should be **ignored gracefully** by old clients.

### Security

- `SIDEMESH_TOKEN` is already stripped from Chrome env.
- Any new backend-eval feature (e.g. remote JS exec) must be gated behind explicit capability flags and should require user approval.

---

## Suggested First Sprint

1. **01** + **09** (gesture fixes + missing input events) — highest user impact, smallest code change.
2. **04** (console logs) — immediately useful for anyone debugging a web app through Sidemesh.
3. **05** (load/error indicators) — pairs naturally with console logs to form a "debugging toolbar."

---

*This document was produced by codebase investigation on 2026-05-04. Each linked file contains the detailed study, CDP API references, exact file/line citations, and a step-by-step implementation plan.*
