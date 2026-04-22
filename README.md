# Sidemesh

Sidemesh is a fleet-first mobile control plane for Codex sessions.

This repo contains:

- a Node daemon that owns a single local `codex app-server` process over stdio
- a Flutter client that can store multiple hosts and connect to each one manually

## Quick start

From this directory:

```bash
npm install
npm run mobile:get
npm run daemon
```

If `SIDEMESH_TOKEN` is not set, the daemon generates one on startup and prints it.

Optional environment variables:

```bash
SIDEMESH_LABEL=MacBook
SIDEMESH_PORT=8787
SIDEMESH_TOKEN=your-shared-token
SIDEMESH_CODEX_BIN=codex
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
- `GET /api/sessions/:sessionId/log`
- `GET /api/sessions/:sessionId/status`
- `POST /api/sessions/create`
- `POST /api/sessions/:sessionId/input`
- `POST /api/sessions/:sessionId/stop`
- `POST /api/actions/:actionId/respond`
- `WS /api/live?sessionId=...`

All `/api/*` routes and the websocket require `Authorization: Bearer <token>`.

## Mobile app

The Flutter app does manual host registration for fast dogfooding:

- label
- base URL
- shared token

That makes it easy to point the phone at a MacBook or VPS over Tailscale without adding a pairing protocol yet.

Current limits:

- tokens are stored in `SharedPreferences`, not secure storage
- the iOS and Android builds allow plain `http://` traffic so Tailscale and private LAN nodes work immediately
- the daemon is Codex-only for now; there is no Pi adapter or multi-agent adapter layer yet
