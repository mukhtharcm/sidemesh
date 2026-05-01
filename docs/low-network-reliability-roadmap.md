# Low-Network Reliability Roadmap

Sidemesh is meant to work while travelling, on weak mobile data, and against
small VPSes. The current implementation is good enough for normal private
network use, but it is not yet Mosh-level. This document tracks the remaining
work needed to make Sidemesh feel trustworthy under packet loss, high latency,
network switching, and low-resource hosts.

## Current Baseline

Already implemented:

- Recent sessions are cache-first and use websocket snapshots before falling
  back to HTTP.
- Initial session detail can paint a cached transcript before the fresh host
  snapshot arrives.
- Session resume marks in-memory transcripts as possibly stale and shows
  reconnecting/offline UI instead of silently showing old state.
- Session detail tracks the host's latest successful contact and can show
  messages such as `Reconnecting - last connected 12s ago` or
  `Offline - last connected 2m ago`.
- Session live events carry sequence IDs and the client can request delta replay
  with `/api/sessions/:sessionId/events?since=<seq>`.
- Terminal output has replay buffers and reconnects with `since`.
- Browser preview can reuse persistent browser profiles and pause hidden views.
- Services have memory caps and terminal child processes now seed sane
  interactive env values such as `HOME`, `USER`, `LOGNAME`, and `SHELL`.

Known limitation:

- Delta replay currently reduces network payload, but for Codex it can still
  require the daemon to scan the rollout log server-side. This is better for the
  client network, but not yet optimal for low-CPU VPSes or very large sessions.

Live investigation on `cortex-dev` also found these concrete issues:

- Reconnect scheduling was host-scoped: one healthy socket could clear the retry
  timer for another dead socket on the same host.
- `/api/sessions/:sessionId/events?since=0` could return much more JSON than the
  paged transcript snapshot when the client cursor was stale.
- Workspace filesystem routes refreshed their allowed roots by listing sessions,
  so file reads/listing were indirectly coupled to provider session-list latency.
- We need a lightweight daemon health endpoint so memory/cache growth can be
  inspected from the app without SSH.

## Priority 1: Connection Awareness UI

Goal: make the app honest about connection freshness everywhere.

The user should always know whether they are seeing live state, recently synced
state, or cached/stale state.

Completed:

- `HostStatusStore` now carries `lastOnlineAt` and `lastEventAt`.
- Successful session live events update `lastEventAt`.
- Session detail stale/reconnecting/offline banners can show the last connected
  age (`_CachedTranscriptStrip` with `_TranscriptFreshnessMode`).
- Background resume no longer silently leaves an in-memory transcript looking
  fresh while resync is still happening.
- `RelativeTimeTicker` provides a lightweight process-wide 1Hz ticker so relative
  time labels (e.g. "last connected 12s ago") stay fresh without every widget
  running its own timer.
- `HostReconnectScheduler` provides centralized per-host reconnect scheduling
  with priority-based slots (`foregroundSession`, `visibleSupport`,
  `backgroundSocket`), exponential backoff tables, and ±30% jitter.

Still missing from this priority:

- Recent, Hosts, and Inbox still need the richer freshness labels; most of the
  app still behaves like green/red/probing dots.
- Terminal panes do not yet show `last output`, `last connected`, or
  `reconnecting` status.
- Browser preview panes do not yet show `last frame`, `paused`, or reconnect
  age.
- We do not measure latency or RTT yet.
- We do not yet have a centralized `ConnectionQualityStore`; the first slice
  extended `HostStatusStore`.
- We do not yet record a full connection timeline for debugging reconnect
  loops.

Track this per host and per active session:

- `state`: `connected`, `syncing`, `reconnecting`, `offline`, `stale`.
- `lastOnlineAt`: last successful websocket hello, snapshot, HTTP response, or
  event replay.
- `lastEventAt`: last live event received for the active session.
- `lastSyncStartedAt`: when the current reconnect/resync attempt began.
- `lastError`: latest transport or API error, sanitized for display.
- `rttMs`: optional round-trip estimate from ping/health checks.

UX:

- In session detail, show:
  - `Connected now`
  - `Reconnecting - last connected 12s ago`
  - `Offline - showing cached state from 2m ago`
  - `Slow network - syncing latest events`
- In Recent/Hosts, show host freshness using the same state model instead of
  only red/green dots.
- In Browser/Terminal panes, show a small transport status chip:
  - `Live`
  - `Reconnecting`
  - `Last frame 8s ago`
  - `Paused`

Implementation notes:

- Extend `HostStatusStore` or add a sibling `ConnectionQualityStore`.
- Websocket `hello`, `snapshot`, `upsert`, `activity`, terminal frames, browser
  frames, and successful HTTP calls should update the same store.
- Do not spam `setState` every second from every widget. Store timestamps and
  have one lightweight ticker only for visible relative-time labels.

Why this matters:

- On bad networks, user trust is more important than hiding the problem.
- Mosh feels reliable partly because it tells you when the last connection was
  active. Sidemesh should do the same.

## Priority 2: True Incremental Session Replay

Goal: make delta replay cheap enough for small VPSes and large sessions.

Completed:

- `session-replay-index.ts` implements an incremental parser for Codex rollout
  `.jsonl` files with bounded ring buffers.
- Detects file rotation via `inode`/`dev`/`size`/`prefixHash` and rebuilds only
  when needed; otherwise parses only appended bytes.
- Emits a typed `STALE_CURSOR` error when a client requests a `since` seq older
  than the retained ring buffer, signaling the client must re-sync.
- `/api/sessions/:sessionId/events?since=<seq>` serves deltas without
  re-scanning the whole file.

Still missing:

- Session-level resource cache so model/profile/skill metadata does not need
  to be re-fetched on every reconnect.
- A lightweight in-memory index that maps seq ranges to file offsets so the
  daemon can serve a delta range without scanning from the start of the log.
- Client-side cursor persistence so the app does not lose its place across
  process restarts.

## Priority 3: Low Data Mode

Goal: give users explicit control over background traffic and preview quality.

Not yet started.

Features:

- Toggle in settings: `Low Data Mode`.
- When enabled:
  - Pause browser preview auto-refresh; require manual tap to resume.
  - Reduce background polling frequency for Recent/Inbox.
  - Do not auto-attach terminals or browser previews when opening a session.
  - Compress large file reads if the host supports it.
- Show a persistent banner when Low Data Mode is active.

## Priority 4: Centralized Reconnect Scheduling

Goal: prevent one healthy socket from masking a broken one on the same host.

Completed:

- `HostReconnectScheduler` replaces independent per-pane reconnect timers with
  a single per-host scheduler.
- Each pane registers a `_ReconnectSlot` with a `ReconnectPriority`:
  - `foregroundSession`: immediate reconnect, 0ms–8s backoff table.
  - `visibleSupport`: 500ms–15s backoff table.
  - `backgroundSocket`: 2s–30s backoff table.
- Delay is computed from the highest-priority disconnected slot.
- ±30% jitter applied, clamped to 100ms–30s.
- `HostRetryState` exposes `isConnected`, `nextRetryAt`, `attemptCount`, and
  `remaining` duration for UI countdowns.
- `markConnected` / `markDisconnected` are slot-scoped by default so a healthy
  background socket does not cancel retry for a broken foreground session.

Still missing:

- Connection timeline UI (connected → closed → scheduled → fallback → snapshot).
- Per-host concurrency limiter for expensive snapshot/log requests.
- Prioritize visible foreground session over background panes when scheduling
  HTTP fallback requests.

## Priority 5: Payload Compression

Goal: reduce JSON payload size for transcripts and metadata.

Completed:

- HTTP compression middleware (`compression`) is installed in `server.ts`.
- `/healthz` is explicitly skipped (no compression overhead for probes).
- Large JSON responses (e.g. session logs) are gzip-compressed when the client
  accepts it.
- Small responses below the default threshold are left uncompressed.
- Test coverage in `compression.test.ts` validates the filter behavior.

Still missing:

- Websocket per-message deflate for JSON event streams.
- Do not enable websocket compression blindly; measure CPU/memory impact on
  small VPSes first.

## Priority 6: Adaptive Browser Preview

Goal: keep browser streaming usable without killing the VPS or the network.

Current risk:

- Pixel streaming is inherently expensive compared with HTML port forwarding.
- Low-quality networks need adaptive behavior, not a fixed frame cadence.

Not yet started.

Improvements:

- Track dropped/late frames per preview client.
- Dynamically lower frame rate and JPEG quality when the client is behind.
- Pause automatically when:
  - app is backgrounded
  - preview is minimized
  - another route covers the preview
- Add a visible manual resume button.
- Add "preview quality" presets:
  - `Readable`
  - `Balanced`
  - `Low data`
- Avoid multiple Chromium instances per persistent profile; reuse or reject.

Do not do:

- Do not stream full-resolution frames continuously on mobile by default.
- Do not enable remote browser preview automatically for every port forward.

## Priority 7: Offline-Safe User Input

Goal: user messages should survive temporary disconnects.

Completed:

- `SessionSendOutboxStore` persists queued sends to `SharedPreferences` with
  host fingerprint scoping.
- `SessionSendOutboxWorker` runs foreground-only retries every 30s with a max
  of 3 sends per pass.
- `PendingSessionSend` carries full context: host, session, client message ID,
  text, input items, overrides, retry count, and last error.
- `PendingSendAnalysis` classifies failures into `PendingSendIssueKind`:
  `hostDisabled`, `hostMissing`, `hostChanged`, `unauthorized`, `timeout`,
  `unreachable`, `server`, `rateLimited`, `unknown`.
- `PendingSendDisplayState` exposes `queued`, `retrying`, `blocked`.
- `pending_send_recovery.dart` provides recovery messages and action guidance.

Still missing:

- Visible queued message UI in the session timeline (currently the outbox
  stores the data but the timeline does not render pending sends inline).
- Keep a visible "queued / sending / accepted / failed" lifecycle per message.
- Allow user to cancel queued sends before reconnect.
- Prevent duplicate sends after timeout (the dedupe store exists server-side
  but the client does not yet surface this protection to the user).

This is especially important for mobile because the OS can suspend sockets
while the user is switching apps.

## Priority 8: Observability And Debugging

Goal: make failures diagnosable without SSHing into the VPS every time.

Completed:

- `/api/diagnostics` returns a lightweight JSON payload with:
  - `label`, `hostname`, `platform`, `uptimeSeconds`
  - `memory` (`process.memoryUsage()`)
  - `resourceUsage` (`process.resourceUsage()`)
  - `caches`: sizes for recent sessions, logs, replay, active turns, pending
    actions, live activity, session seq cursors, input dedupe
  - `sockets`: session rooms, live sockets, approval sockets, recent session
    sockets
  - `features`: active terminals, port forwards, browser previews
- `/api/debug/codex-rpc-audit` exposes Codex RPC audit snapshot.

Still missing:

- Per-host connection timeline:
  - connected
  - websocket closed
  - reconnect scheduled
  - HTTP fallback started
  - snapshot loaded
  - delta replay failed
- Per-feature counters:
  - recent websocket reconnects
  - session replay fallbacks
  - terminal dropped clients
  - browser preview frame drops
  - port forward reconnects
- Do not log secrets:
  - Never log bearer tokens.
  - Never log full terminal input.
  - Never log full file paths in public diagnostics unless the user explicitly
    opens local diagnostics.

## Recommended Execution Order

1. ✅ Add connection freshness model and "last connected N seconds ago" UI.
2. ✅ Add server-side per-session replay index for true cheap delta replay.
3. ⬜ Add Low Data Mode with browser preview and background refresh throttles.
4. ✅ Add centralized per-host reconnect scheduling with jitter.
5. ✅ Add targeted HTTP compression for large JSON endpoints.
6. ⬜ Add browser preview adaptive quality/fps.
7. ⬜ Harden offline send queue UI (visible timeline rendering + cancel).
8. ✅ Add diagnostics surface (`/api/diagnostics`); still needs per-host timeline.

## Acceptance Criteria

Sidemesh should pass these manual scenarios:

- Open a session, background the app for 5 minutes, return on bad network:
  stale/reconnecting state is visible immediately, then clears after sync.
- Disable network while viewing a session:
  app keeps cached transcript visible and shows last connected time.
- Re-enable network:
  app catches up using delta replay without full transcript reload if possible.
- Open Recent with two slow hosts:
  cached sessions paint quickly; live hosts update independently; one bad host
  does not block the whole list.
- Watch the same terminal from two clients, disconnect one, reconnect it:
  terminal resumes from replay or clearly asks for a fresh attach.
- Start browser preview on mobile, background app, return:
  preview is paused or reconnected intentionally, not silently dead.
- Run on a small VPS:
  memory stays bounded under terminal/browser/session reconnect churn.
