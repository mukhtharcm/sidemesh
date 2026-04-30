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

## Priority 1: Connection Awareness UI

Goal: make the app honest about connection freshness everywhere.

The user should always know whether they are seeing live state, recently synced
state, or cached/stale state.

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

Goal: reconnect without rereading and reserializing whole transcripts.

Current problem:

- `/api/sessions/:sessionId/events?since=<seq>` sends only new events to the
  client.
- For Codex, the server may still parse the entire rollout `.jsonl` file to
  compute those new events.
- Large sessions on small VPSes can still cost CPU, disk IO, and latency.

Better architecture:

- Maintain a daemon-side per-session replay index:
  - `sessionId`
  - rollout file path
  - file inode/device if available
  - last byte offset read
  - last parsed seq
  - bounded event ring buffer
  - latest runtime summary
  - latest thread updatedAt
- On first read, parse the file once and cache the normalized events.
- On later reads, stat the file and parse only appended bytes.
- If the file shrinks, rotates, or inode changes, invalidate and rebuild.
- `/events?since=n` should serve directly from the ring buffer when possible.
- If `since` is older than the retained ring buffer, return a specific
  `410 stale_cursor`-style response so the client knows to request a snapshot.

Data limits:

- Keep only a bounded event ring per session.
- Track memory usage and evict least-recently-used session indexes.
- Keep active sessions warm; cold sessions can rebuild on demand.

Expected impact:

- Much faster app resume.
- Less disk IO on VPSes.
- Less CPU when multiple clients view the same session.
- Cleaner foundation for “last connected N seconds ago” because server replay
  becomes reliable and cheap.

## Priority 3: Low Data Mode

Goal: give users a mode that sacrifices freshness/detail for survival on weak
networks.

App-level or host-level setting:

- Reduce recent session limit, for example from 40 to 15.
- Prefer websocket snapshots; delay HTTP fallback longer.
- Disable automatic git status refresh unless the git panel is visible.
- Disable automatic skills/profile refresh until composer uses `$` or settings
  are opened.
- Pause browser preview when minimized or offscreen.
- Lower browser preview quality and frame rate.
- Reduce terminal replay request size if a client is far behind.
- Avoid downloading full image attachments until tapped.

Possible labels:

- `Normal`
- `Low Data`
- `Survival`

Default:

- Keep `Normal` as default.
- Auto-suggest Low Data when repeated timeouts or high reconnect counts are
  observed.

## Priority 4: Better Reconnect Backoff And Jitter

Goal: avoid reconnect storms across Recent, Inbox, Session, Terminal, Browser,
and FS sockets.

Problems to avoid:

- App resumes and every pane reconnects immediately.
- Multiple hosts all perform HTTP fallback at the same time.
- Slow VPS gets hammered by snapshot requests after a temporary outage.

Improvements:

- Centralize reconnect scheduling per host.
- Use exponential backoff with jitter.
- Use a per-host concurrency limiter for expensive snapshot/log requests.
- Prioritize visible foreground session over background panes.
- Let Recent/Inbox accept stale cache while the active session reconnects first.
- Show retry countdowns in UI for clarity.

Suggested policy:

- Immediate reconnect for the visible session.
- 500ms to 2s jitter for visible support sockets.
- 2s to 10s jitter for Recent/Inbox background sockets.
- Longer retry after repeated failures, capped at about 30s.

## Priority 5: Payload Compression

Goal: reduce JSON payload size for transcripts and metadata.

Candidates:

- Enable gzip/br compression for HTTP JSON responses.
- Consider websocket per-message deflate for JSON event streams only.
- Do not blindly compress binary/image/browser frames.

Risks:

- Compression costs CPU on small VPSes.
- Browser preview frames are already compressed images, so generic compression
  usually wastes CPU.
- Websocket compression can increase memory usage if not configured carefully.

Recommendation:

- Start with HTTP compression for large JSON endpoints only:
  - session log
  - session resources
  - file previews
- Measure before enabling websocket compression globally.

## Priority 6: Adaptive Browser Preview

Goal: keep browser streaming usable without killing the VPS or the network.

Current risk:

- Pixel streaming is inherently expensive compared with HTML port forwarding.
- Low-quality networks need adaptive behavior, not a fixed frame cadence.

Improvements:

- Track dropped/late frames per preview client.
- Dynamically lower frame rate and JPEG quality when the client is behind.
- Pause automatically when:
  - app is backgrounded
  - preview is minimized
  - another route covers the preview
- Add a visible manual resume button.
- Add “preview quality” presets:
  - `Readable`
  - `Balanced`
  - `Low data`
- Avoid multiple Chromium instances per persistent profile; reuse or reject.

Do not do:

- Do not stream full-resolution frames continuously on mobile by default.
- Do not enable remote browser preview automatically for every port forward.

## Priority 7: Offline-Safe User Input

Goal: user messages should survive temporary disconnects.

Already partially present:

- Pending send/outbox logic exists.

Needed:

- Show queued messages clearly when host is offline.
- Retry with the same client message ID.
- Keep a visible “queued / sending / accepted / failed” lifecycle.
- Prevent duplicate sends after timeout.
- Allow user to cancel queued sends before reconnect.

This is especially important for mobile because the OS can suspend sockets
while the user is switching apps.

## Priority 8: Observability And Debugging

Goal: make failures diagnosable without SSHing into the VPS every time.

Add lightweight diagnostics:

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
- Daemon health endpoint fields:
  - uptime
  - memory RSS
  - active terminals
  - active browser previews
  - active port forwards
  - active websocket counts
  - provider health summary

Do not log secrets:

- Never log bearer tokens.
- Never log full terminal input.
- Never log full file paths in public diagnostics unless the user explicitly
  opens local diagnostics.

## Recommended Execution Order

1. Add connection freshness model and “last connected N seconds ago” UI.
2. Add server-side per-session replay index for true cheap delta replay.
3. Add Low Data Mode with browser preview and background refresh throttles.
4. Add centralized per-host reconnect scheduling with jitter.
5. Add targeted HTTP compression for large JSON endpoints.
6. Add browser preview adaptive quality/fps.
7. Harden offline send queue UI.
8. Add diagnostics surfaces.

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

