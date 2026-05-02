# Sidemesh

Sidemesh is a fleet-first mobile control plane for agent sessions. The daemon
ships with provider adapters for Codex, GitHub Copilot CLI, Pi (via the Pi SDK), and a deterministic
fake test provider, while the server/client boundaries are structured around
provider capabilities so more coding agents can be added behind the same API.

Sidemesh is open source under Apache-2.0. The npm package is not published
yet, and daemon access should stay on trusted networks such as Tailscale or a
private LAN.

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
npm run build           # compile the daemon CLI into dist/
npm run setup           # guided config wizard
npm run doctor          # startup and provider diagnostics
npm run status          # resolved config + local daemon health
npm run pair            # host URL + token for the mobile app
npm run daemon          # start the foreground dev server through tsx
npm run daemon:compiled # start the foreground compiled server
npm run secret:scan     # scan the working tree with gitleaks when installed
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

## Installing The Daemon CLI

For day-to-day host operation, prefer the compiled `sidemesh` CLI instead of
running `npm run daemon` from the repo. The compiled path does not depend on
`tsx` at runtime, so it avoids optional esbuild package failures from
production-style installs.

For local development:

```bash
npm install
npm link
sidemesh setup
sidemesh start
sidemesh pair
```

For a trusted machine that should consume the repo directly before npm
publishing is set up:

```bash
npm install -g github:mukhtharcm/sidemesh
sidemesh setup
sidemesh start
sidemesh pair
```

Lifecycle commands:

```bash
sidemesh daemon          # foreground mode; useful under systemd or while debugging
sidemesh start           # detached background daemon
sidemesh stop            # warns before stopping the managed daemon
sidemesh restart         # warns, then stop + start
sidemesh restart --yes   # non-interactive restart for scripts
sidemesh status          # config, health, and managed daemon pid/state
sidemesh service install # install/update systemd or LaunchAgent wrapper
sidemesh service restart # restart the OS service wrapper
sidemesh service uninstall # stop and remove the OS service wrapper
```

The lifecycle commands write managed process state to
`~/.sidemesh/daemon-state-v1.json` by default. If another managed daemon is
already healthy on the configured port, `sidemesh daemon` and `sidemesh start`
refuse to launch a duplicate. If a daemon responds on the port but no managed
state exists, Sidemesh warns instead of blindly killing an unknown process.

On Linux hosts that should run Sidemesh as a boot service, install the systemd
wrapper after `npm install` and `npm run build`:

```bash
sudo sidemesh service install
sidemesh service status
sudo sidemesh service restart --yes
sudo sidemesh service uninstall --yes
```

`service install` writes a unit, private env file, and launcher script. The
generated launcher runs the compiled CLI (`dist/cli.js daemon`) instead of
`tsx`, which avoids esbuild optional-dependency runtime failures. The command
uses the config resolved at install time, so run setup/install against the
config the service should use, or pass `--config /path/to/config.json`
explicitly.

On macOS, the same command installs a user LaunchAgent instead of a root
daemon. Do not use `sudo`; the agent needs your normal user config, token,
keychain, and shell environment:

```bash
sidemesh service install
sidemesh service status
sidemesh service restart --yes
sidemesh service uninstall --yes
```

The default launchd label is `dev.sidemesh.daemon`, and generated files live
under `~/Library/LaunchAgents` and `~/.sidemesh/launchd`. If a managed
foreground/background Sidemesh daemon is already running, `service install`
stops it before bootstrapping the LaunchAgent so launchd does not enter a
duplicate-start loop.

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
SIDEMESH_ENABLE_COPILOT=0
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
SIDEMESH_TERMINAL_REQUIRE_PTY=0
SIDEMESH_PORT_FORWARDING=0
SIDEMESH_PORT_FORWARDING_ALLOW_NON_LOOPBACK=0
SIDEMESH_BROWSER_PREVIEW=0
SIDEMESH_BROWSER_PREVIEW_CHROME_PATH=
SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS=8
SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS=3600000
SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS=900
SIDEMESH_BROWSER_PREVIEW_QUALITY=55
```

`SIDEMESH_PROVIDER` defaults to `codex`. Copilot is experimental and disabled
unless `SIDEMESH_ENABLE_COPILOT=1` is set. `SIDEMESH_PROVIDER_COMMAND` is a
provider-neutral command override; provider-specific command variables such as
`SIDEMESH_CODEX_BIN` and `SIDEMESH_COPILOT_BIN` take precedence.

Integrated terminal access is host-side and provider-neutral. It is disabled by
default because it exposes an interactive shell on the host. `npm run setup`
now asks whether to enable it and persists that choice in the config file. For
temporary overrides, set `SIDEMESH_TERMINAL=1` to advertise the
`workspace.terminal` capability and enable `/api/terminals`.

The daemon uses `node-pty` when available and falls back to a pipe-backed shell
if PTY spawning fails; set `SIDEMESH_TERMINAL_REQUIRE_PTY=1` if you prefer hard
failure over fallback. If `node-pty` installs but cannot spawn shells on a local
Node runtime, the daemon attempts to repair the known macOS `spawn-helper`
execute-bit issue before falling back; if PTY startup still fails, run
`npm rebuild node-pty`. Pipe fallback is intentionally labeled as limited in the
app; it has no real PTY resize semantics, but the daemon still terminates the
whole fallback process group when you stop the terminal.

Port forwarding is also host-side and provider-neutral. It is disabled by
default because it lets authenticated clients reach services from the host.
Enable it with `SIDEMESH_PORT_FORWARDING=1` or through `sidemesh setup`; the
default target policy only allows the daemon to connect to `localhost`/
`127.0.0.1` on the host. Set
`SIDEMESH_PORT_FORWARDING_ALLOW_NON_LOOPBACK=1` only if you intentionally want
the daemon to bridge to other addresses reachable from that host.

Remote browser preview is an optional layer on top of HTTP/HTTPS port
forwards. It starts Chrome/Chromium on the host, captures compressed page
frames, and streams those pixels to authenticated clients. Keep it disabled on
hosts that should not run headless Chrome. When enabled, tune resource usage
with `SIDEMESH_BROWSER_PREVIEW_MAX_PREVIEWS`,
`SIDEMESH_BROWSER_PREVIEW_IDLE_TTL_MS`,
`SIDEMESH_BROWSER_PREVIEW_FRAME_INTERVAL_MS`, and
`SIDEMESH_BROWSER_PREVIEW_QUALITY`; lower quality and slower frame intervals
reduce CPU and bandwidth. The app closes its viewer socket when the preview
route is not active or the app backgrounds, but the daemon-side browser remains
available until it is stopped or idle-cleaned.

Browser previews can run with a temporary browser profile or the saved Sidemesh
browser profile. Temporary profiles are deleted when the preview stops. The
saved Sidemesh profile lives under the daemon state directory at
`browser-profiles/sidemesh` and keeps normal browser state such as cookies,
local storage, IndexedDB, service workers, and cached login sessions. Treat that
directory as sensitive: anyone with access to the daemon host may be able to use
the saved web sessions. Sidemesh does not use your normal Chrome profile.

To run against GitHub Copilot CLI instead of Codex without using the setup
wizard:

```bash
SIDEMESH_ENABLE_COPILOT=1 \
SIDEMESH_PROVIDER=copilot \
SIDEMESH_LABEL=copilot-node \
SIDEMESH_TOKEN=replace-me \
npm run daemon
```

The Copilot provider is the first real non-Codex adapter, but it stays behind
the explicit `SIDEMESH_ENABLE_COPILOT=1` flag while its UX contract is being
hardened. It reads native Copilot SDK for session discovery, transcript replay,
model metadata, streaming turns, resume, interruption, tool activity,
permission requests, image input, skills, and interactive input. It does not
read Copilot's on-disk session files directly. Sidemesh does not maintain a
hand-written Copilot model catalog; the model picker is built from SDK
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
sidemesh setup
sidemesh doctor
sidemesh start
sidemesh pair
```

Use `sidemesh daemon` instead of `sidemesh start` when you want a foreground
process, for example inside `systemd` or during local debugging.

Use `sidemesh status` when you are unsure which local daemon is active. It
prints the resolved port, provider list, token fingerprint, terminal and port
forwarding settings, managed daemon pid/state, and reachable local/Tailscale
addresses without revealing the full token.

If you prefer raw env vars, this still works:

```bash
SIDEMESH_LABEL=mbp \
SIDEMESH_PORT=8899 \
SIDEMESH_TOKEN=replace-me \
sidemesh daemon
```

Then add that machine inside the mobile app by scanning the QR code printed by
`sidemesh pair` from the host editor. Manual entry still works with these
fields:

- `label`: any friendly name such as `MacBook`, `nyc-vps`, or `lab-box`
- `base URL`: one of the addresses shown by `sidemesh pair`
- `token`: the token shown by `sidemesh pair`

Examples:

- `http://100.94.10.20:8899`
- `http://macbook.tailnet.ts.net:8899`

The QR payload is still local-first: it contains the selected base URL and
shared token, but there is no pairing server or browser relay.

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

## Release Hygiene

Release tracking lives in `TODO.md`, and the private developer-preview release
process lives in `docs/release-playbook.md`.

GitHub Actions currently provide:

- CI for server typecheck/tests/build/package dry-run.
- CI for focused Flutter tests and analysis.
- A manual `Mobile Artifacts` workflow for unsigned Android, macOS, and iOS
  simulator builds.
- A `Release macOS App` workflow for ZIP/DMG packaging, optional Developer ID
  signing, optional notarization, and optional GitHub Release publishing. This
  is manual-only so server tags do not spend macOS CI minutes.
- A manual `Deploy to TestFlight` workflow for signed iOS uploads.
- A `Deploy Website` workflow for the Cloudflare Pages marketing site in
  `web/`; it runs on `main` only when `web/**` changes.
- A manual `Secret Scan` workflow for a full-history gitleaks scan.

Before changing repository visibility or distributing to untrusted users, run:

```bash
npm run secret:scan
scripts/secret-scan.sh --history
```

Do not expose a Sidemesh daemon directly to the public internet. The current
auth model is a shared bearer token with no per-device revocation yet.

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

The Flutter app supports QR and manual host registration for fast dogfooding:

- label
- base URL
- shared token

Run `sidemesh pair` on a host to print a QR code, then scan it from the host
editor in the app. Manual entry still works for desktop clients or locked-down
camera environments.

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

- host tokens are stored in platform secure storage, but token revocation is
  not implemented yet
- the iOS and Android builds allow plain `http://` traffic so Tailscale and private LAN nodes work immediately
- Codex and Pi are the production-ready providers; the Copilot adapter is
  experimental and disabled by default, and the fake provider is the
  deterministic contract test adapter
- provider registration is centralized in `src/provider-registry.ts`; future
  adapters should start there instead of adding new config/factory switches
- the provider adapter contract is documented in
  `docs/provider-adapter-contract.md`
- the server assumes a trusted private network or equivalent protection around each daemon
