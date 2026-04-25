# Sidemesh

Sidemesh is a fleet-first mobile control plane for Codex sessions.

This repo contains:

- a Node daemon that owns a single local `codex app-server` process over stdio
- a Flutter client that can store multiple hosts and connect to each one manually
- a mobile/desktop control surface for chat, approvals, session policy, workspace files, and live activity

## Quick start

From this directory:

```bash
npm install
npm run mobile:get
npm run daemon
```

If `SIDEMESH_TOKEN` is not set, the daemon generates one on startup and prints it.
The daemon stores lightweight local state in `SIDEMESH_STATE_DIR`, defaulting to
`~/.sidemesh`; this currently includes a bounded send-retry ledger for
`clientMessageId` replay protection.

Optional environment variables:

```bash
SIDEMESH_LABEL=MacBook
SIDEMESH_PORT=8787
SIDEMESH_TOKEN=your-shared-token
SIDEMESH_CODEX_BIN=codex
SIDEMESH_STATE_DIR=~/.sidemesh
```

## Dogfood flow

Run one daemon per machine you want to reach from the phone:

```bash
SIDEMESH_LABEL=mbp \
SIDEMESH_PORT=8899 \
SIDEMESH_TOKEN=replace-me \
npm run daemon
```

Then add that machine inside the mobile app with:

- `label`: any friendly name such as `MacBook`, `nyc-vps`, or `lab-box`
- `base URL`: `http://<tailscale-ip-or-hostname>:8899`
- `token`: the same `SIDEMESH_TOKEN`

Examples:

- `http://100.94.10.20:8899`
- `http://macbook.tailnet.ts.net:8899`

That gives you a manual, fleet-first setup without any pairing server or browser client.

## Running the mobile app

For local Flutter development:

```bash
cd apps/mobile
flutter run -d <device-id>
```

To install a debug build directly:

```bash
cd apps/mobile
flutter build apk --debug
flutter install --debug -d <device-id>
```

## Daemon API

- `GET /healthz`
- `GET /api/node`
- `GET /api/workspaces`
- `GET /api/sessions`
- `GET /api/actions`
- `GET /api/sessions/:sessionId/log`
- `GET /api/sessions/:sessionId/resources`
- `GET /api/sessions/:sessionId/events?since=<seq>`
- `GET /api/sessions/:sessionId/status`
- `POST /api/sessions/create`
- `POST /api/sessions/:sessionId/input`
- `POST /api/sessions/:sessionId/stop`
- `POST /api/sessions/:sessionId/name`
- `POST /api/sessions/:sessionId/archive`
- `POST /api/sessions/:sessionId/unarchive`
- `POST /api/actions/:actionId/respond`
- `WS /api/live?sessionId=...`

Workspace filesystem endpoints:

- `GET /api/fs/roots`
- `GET /api/fs/list?path=...`
- `GET /api/fs/metadata?path=...`
- `GET /api/fs/read?path=...`
- `POST /api/fs/write`
- `POST /api/fs/createDir`
- `POST /api/fs/remove`
- `POST /api/fs/copy`
- `WS /api/fs/live`

All `/api/*` routes and websocket endpoints require `Authorization: Bearer <token>`.
`GET /healthz` is intentionally unauthenticated for local service checks.

## Mobile app

The Flutter app does manual host registration for fast dogfooding:

- label
- base URL
- shared token

That makes it easy to point the phone at a MacBook or VPS over Tailscale without adding a pairing protocol yet.

The app currently supports:

- recent sessions across hosts
- host detail and workspace summaries
- pending approval inbox
- live chat with reconnect/delta replay
- per-session resources view for links, images, and local artifacts
- per-session approval, sandbox, model, and network controls
- command, file-change, terminal-input, and turn-diff activity cards
- session rename, archive, unarchive, favorite, and unread state
- workspace file browsing, reading, editing, and live file-change refresh

Current limits:

- host tokens are stored in platform secure storage, but pairing/revocation is not implemented yet
- the iOS and Android builds allow plain `http://` traffic so Tailscale and private LAN nodes work immediately
- the daemon is Codex-only for now; there is no Pi adapter or multi-agent adapter layer yet
- the server assumes a trusted private network or equivalent protection around each daemon
