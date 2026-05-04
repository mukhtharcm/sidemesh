# Browser Preview Redesign + DevTools — Implementation Plan

## Goal

Transform the browser preview from a "tucked-aside video stream" into a **first-class remote browser experience** with integrated DevTools.

## Motivation

Current problems:
- AppBar says "Stream pixels" — abstract and unhelpful
- Viewport is boxed inside a card with padding — feels like a widget, not a browser
- No URL editing, no page title, no favicon
- Floating buttons feel disconnected
- No DevTools — console logs, network, storage are invisible
- Desktop has no inspector surface for browser preview

## Design Principles

1. **It is a browser, not a stream** — edge-to-edge viewport, proper chrome
2. **Tools are first-class** — DevTools toggle is always visible
3. **Desktop parity** — inspector surface, not just modals
4. **Per-preview scoping** — each preview gets its own DevTools context

## Implementation Phases

### Phase 1: Backend CDP Additions

#### 1.1 Console log streaming
- Enable `Runtime` + `Log` domains in `startPreview`
- Listen to `Runtime.consoleAPICalled`, `Runtime.exceptionThrown`, `Log.entryAdded`
- Rate-limit with ring buffer (max 256 entries, flush every 500ms or 32 items)
- Forward as `{type: "console", level, args, timestamp, url?, line?, column?}`

#### 1.2 Page load / error indicators
- Listen to `Page.frameStartedLoading`, `Page.loadEventFired`
- Forward as `{type: "loading", state: "started" | "complete"}`
- Navigation errors: `{type: "navError", url, error}`

#### 1.3 Input pipeline improvements
- Add `tapDown` / `tapUp` message types (backward-compatible with `tap`)
- Add `touchStart` / `touchMove` / `touchEnd` for mobile fidelity
- Add `hover` (throttled to 60Hz)
- Add `navigate` message for URL editing from client

### Phase 2: Flutter UI Redesign

#### 2.1 Chrome bar (replaces AppBar + `_PreviewHeader`)
```
[←] [→] [⟳]  [https://localhost:3000/path]  [🔧] [⏸] [⏹]
```
- Back/forward/reload buttons
- Editable URL field (tap to edit, submit → `navigate` message)
- DevTools toggle, pause, stop

#### 2.2 Edge-to-edge viewport
- Remove `MeshCard` wrapper and padding
- `Image.memory` fills available space with `BoxFit.contain`
- Black background fills aspect-ratio gaps
- `ClipRRect` with 0px radius (or small radius)

#### 2.3 Bottom toolbar (replaces floating controls + input rail)
```
[←] [→] [⟳] [Home] [URL chip] [🔧] [⌨️]
```
- When keyboard active: expands to show text input + special keys
- Fixed at bottom, like Safari mobile

#### 2.4 DevTools panel
- Slide-up from bottom (DraggableScrollableSheet)
- Tabs: Console | Network | Storage | Inspector
- Console: scrollable list with color-coded levels
- Behind `🔧` toggle

### Phase 3: Desktop Inspector Surface

#### 3.1 Add `browserPreview` to `InspectorSurfaceKind`
#### 3.2 Create `buildInspectorBrowserPreviewSurface` helper
#### 3.3 Route desktop browser preview opens to inspector scope

### Phase 4: Gestures & Input

#### 4.1 Replace drag recognizers with pan
#### 4.2 Add tap-down/tap-up split
#### 4.3 Add hover for desktop
#### 4.4 Add touch events for mobile viewports

## Files to Modify

| File | Changes |
|------|---------|
| `src/browser-preview.ts` | CDP subscriptions, new message handlers, ring buffer |
| `apps/mobile/lib/src/screens/browser_preview_screen.dart` | Complete UI refactor |
| `apps/mobile/lib/src/screens/inspector/inspector_controller.dart` | Add `browserPreview` kind |
| `apps/mobile/lib/src/screens/session_screen.dart` | Docked chrome bar, desktop routing |

## New Files

| File | Purpose |
|------|---------|
| `apps/mobile/lib/src/screens/inspector/inspector_browser_preview.dart` | Desktop inspector surface builder |

## Acceptance Criteria

- [ ] Console logs appear in DevTools panel within 1s
- [ ] Page load shows progress indicator
- [ ] URL bar shows actual URL and is editable
- [ ] Viewport is edge-to-edge with no card wrapper
- [ ] Bottom toolbar replaces floating controls
- [ ] Desktop shows browser preview in inspector pane
- [ ] `npm run typecheck` passes
- [ ] `flutter analyze` passes
- [ ] All existing tests pass

## Risks

1. **CDP event spam**: Console ring buffer mitigates
2. **WebSocket bloat**: New message types are additive; old clients ignore unknown types
3. **Flutter Image.memory WebP**: Already supports it
4. **Desktop shell layout**: Browser preview inspector may need min-width constraints

## Dependencies

- Phase 2 depends on Phase 1 (backend events must exist before UI can display them)
- Phase 3 depends on Phase 2 (inspector surface wraps redesigned pane)
- Phase 4 can run parallel to Phase 2/3

## Estimated Effort

- Phase 1: ~2 hours
- Phase 2: ~4 hours
- Phase 3: ~1 hour
- Phase 4: ~2 hours
- Review/fix cycles: ~2 hours
- Total: ~11 hours
