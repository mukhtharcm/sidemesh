# Sidemesh

Sidemesh is a fleet-first mobile control plane for agent sessions. The daemon
ships with provider adapters for Codex, GitHub Copilot CLI, and a deterministic
fake test provider, while the server/client boundaries are structured around
provider capabilities so more coding agents can be added behind the same API.

This repo contains:

- a Node daemon that can expose one or more local agent providers
- a Flutter client that can store multiple hosts and connect to each one manually
- a mobile/desktop control surface for chat, approvals, session policy, workspace files, and live activity

## Quick start

From this directory:

```bash
node --version # requires Node.js 20+
npm install
npm run mobile:get
npm run setup
npm run daemon
```

The first run should go through `sidemesh setup`. That writes a persisted config
to `~/.sidemesh/config.json` by default, including the shared token and selected
providers. The daemon stores lightweight local state in `SIDEMESH_STATE_DIR`,
defaulting to `~/.sidemesh`; this currently includes a bounded send-retry
ledger for `clientMessageId` replay protection.

Useful CLI commands:

```bash
npm run setup           # guided config wizard
npm run doctor          # startup and provider diagnostics
npm run status          # resolved config + local daemon health
npm run pair            # host URL + token for the mobile app
npm run daemon          # start the server
```

`npm run setup` shows public providers by default. If you need the deterministic
fake provider for local contract testing, run `npm run setup -- --dev` or use
the raw environment-variable flow shown below.

Or directly:

```bash
npx tsx src/cli.ts setup
npx tsx src/cli.ts doctor
npx tsx src/cli.ts pair
```

Configuration resolution works like this:

1. CLI `--config` picks which config file to read
2. environment variables override persisted config values
3. persisted config values override built-in defaults

Optional environment variables:

```bash
SIDEMESH_CONFIG=~/.sidemesh/config.json
SIDEMESH_LABEL=MacBook
SIDEMESH_PORT=8787
SIDEMESH_TOKEN=your-shared-token
SIDEMESH_PROVIDER=codex
SIDEMESH_CODEX_BIN=codex
SIDEMESH_PROVIDER_COMMAND=codex
SIDEMESH_COPILOT_BIN=copilot
SIDEMESH_COPILOT_STATE_DIR=~/.sidemesh/copilot-provider
SIDEMESH_COPILOT_ALLOW_ALL=0
SIDEMESH_COPILOT_MODEL=
SIDEMESH_FAKE_LATENCY_MS=15
SIDEMESH_FAKE_SEED=1
SIDEMESH_FAKE_WORKSPACE_ROOT=/tmp/sidemesh-fake
SIDEMESH_FAKE_CAPABILITY_PROFILE=full
SIDEMESH_STATE_DIR=~/.sidemesh
SIDEMESH_TERMINAL=0
SIDEMESH_TERMINAL_SHELL=/bin/zsh
```

`SIDEMESH_PROVIDER` defaults to `codex`. `SIDEMESH_PROVIDER_COMMAND` is a
provider-neutral command override; provider-specific command variables such as
`SIDEMESH_CODEX_BIN` and `SIDEMESH_COPILOT_BIN` take precedence.

Integrated terminal access is host-side and provider-neutral. It is disabled by
default because it exposes an interactive shell on the host. Set
`SIDEMESH_TERMINAL=1` to advertise the `workspace.terminal` capability and
enable `/api/terminals`. The daemon uses `node-pty` when available and falls
back to a pipe-backed shell if PTY spawning fails; set
`SIDEMESH_TERMINAL_REQUIRE_PTY=1` if you prefer hard failure over fallback.
If `node-pty` installs but cannot spawn shells on a local Node runtime, run
`npm rebuild node-pty`.

To run against GitHub Copilot CLI instead of Codex without using the setup
wizard:

```bash
SIDEMESH_PROVIDER=copilot \
SIDEMESH_LABEL=copilot-node \
SIDEMESH_TOKEN=replace-me \
npm run daemon
```

The Copilot provider is the first real non-Codex adapter. It reads native
Copilot SDK for session discovery, transcript replay, model metadata,
streaming turns, resume, interruption, tool activity, permission requests,
image input, skills, and interactive input. It does not read Copilot's on-disk
session files directly. Sidemesh does not maintain a hand-written Copilot model
catalog; the model picker is built from SDK
`listModels()` metadata and includes Copilot's `auto` selection. Sidemesh
defaults new app-started Copilot turns to `auto` so an expensive persistent
Copilot setting is not used accidentally. Set `SIDEMESH_COPILOT_MODEL`,
`COPILOT_MODEL`, `COPILOT_PROVIDER_MODEL_ID`, or `COPILOT_PROVIDER_WIRE_MODEL`
only when you want a host-level default. By default it does not auto-grant
Copilot tool permissions; set `SIDEMESH_COPILOT_ALLOW_ALL=1` only on hosts
where Sidemesh may approve every Copilot SDK permission request.

For provider-abstraction testing, run the deterministic in-process fake
provider instead of Codex:

```bash
SIDEMESH_PROVIDER=fake \
SIDEMESH_LABEL=fake-node \
SIDEMESH_FAKE_CAPABILITY_PROFILE=full \
SIDEMESH_TOKEN=replace-me \
npm run daemon
```

The fake provider supports every advertised Sidemesh capability and exercises
real app flows without contacting an external agent. Use prompt keywords such
as `tools`, `approval:command`, `approval:file`, `approval:permissions`,
`image`, `slow`, and `fail` to trigger deterministic UI states. Its model
catalog includes normal, provider-managed auto-reasoning, fast-mode, and image
models so provider-neutral model UI can be tested without Codex.

Use `SIDEMESH_FAKE_CAPABILITY_PROFILE` to simulate weaker future providers:

- `full`: every fake capability advertised.
- `chat-only`: text chat and history only; no attachments, tools, approvals,
  model controls, skills, or filesystem.
- `no-files`: chat/tools/config remain, but filesystem and remote git diff are
  not advertised.
- `no-model-controls`: chat/tools/approvals remain, but models, profiles,
  reasoning, and fast mode are not advertised.
- `no-approvals`: chat/tools/config remain, but approval flows are not
  advertised.
- `minimal`: text chat and history only, with rename/archive/interrupt/replay
  disabled too.

To automate the profile checks without manually adding each fake host in the
app, run:

```bash
npm run test:fake-profiles
```

That starts real local fake daemons for each profile and verifies `/api/node`
capabilities plus key route gates.

## Dogfood flow

Run one daemon per machine you want to reach from the phone. The recommended
flow is:

```bash
npm run setup
npm run doctor
npm run daemon
npm run pair
```

Run `npm run pair` from a second terminal after the daemon is up, since
`npm run daemon` is a long-running process.

If you prefer raw env vars, this still works:

```bash
SIDEMESH_LABEL=mbp \
SIDEMESH_PORT=8899 \
SIDEMESH_TOKEN=replace-me \
npm run daemon
```

Then add that machine inside the mobile app with:

- `label`: any friendly name such as `MacBook`, `nyc-vps`, or `lab-box`
- `base URL`: one of the addresses shown by `sidemesh pair`
- `token`: the token shown by `sidemesh pair`

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
- `GET /api/providers`
- `GET /api/workspaces`
- `GET /api/sessions`
- `GET /api/actions`
- `GET /api/sessions/:sessionId/log`
- `GET /api/sessions/:sessionId/resources`
- `GET /api/sessions/:sessionId/events?since=<seq>`
- `GET /api/sessions/:sessionId/status`
- `GET /api/sessions/:sessionId/git`
- `GET /api/sessions/:sessionId/git/diff?kind=working|staged|unstaged|remote`
- `GET /api/models`
- `GET /api/profiles`
- `GET /api/skills`
- `POST /api/skills/config`
- `POST /api/sessions/create`
- `POST /api/sessions/:sessionId/input`
- `POST /api/sessions/:sessionId/stop`
- `POST /api/sessions/:sessionId/name`
- `POST /api/sessions/:sessionId/archive`
- `POST /api/sessions/:sessionId/unarchive`
- `POST /api/actions/:actionId/respond`
- `WS /api/live?sessionId=...`
- `WS /api/actions/live`

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
- per-session approval, sandbox, model, and network controls, shown according to
  provider capabilities
- command, file-change, terminal-input, and turn-diff activity cards
- session rename, archive, unarchive, favorite, and unread state
- workspace file browsing, reading, editing, and live file-change refresh
- local git status and local diffs, shown according to daemon host capabilities

Current limits:

- host tokens are stored in platform secure storage, but pairing/revocation is not implemented yet
- the iOS and Android builds allow plain `http://` traffic so Tailscale and private LAN nodes work immediately
- Codex remains the fullest production provider; the Copilot adapter is an
  early text-first provider, and the fake provider is the deterministic contract
  test adapter
- provider registration is centralized in `src/provider-registry.ts`; future
  adapters should start there instead of adding new config/factory switches
- the provider adapter contract is documented in
  `docs/provider-adapter-contract.md`
- the server assumes a trusted private network or equivalent protection around each daemon
