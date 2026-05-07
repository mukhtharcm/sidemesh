# Sidemesh

Sidemesh is a trusted-network control plane for coding-agent sessions. Run the
daemon on your development machine, connect from the Flutter app, and manage
sessions, approvals, files, git, terminals, port forwards, and browser
previews from mobile or desktop.

This repository contains:

- `src/`: the Node.js daemon, CLI, provider adapters, and host-side APIs
- `apps/mobile/`: the Flutter client
- `web/`: the landing site deployed separately

## Providers

Sidemesh currently supports these provider adapters:

| Provider | Status | Notes |
| --- | --- | --- |
| Codex | primary | default setup option |
| Pi | supported | public setup option |
| GitHub Copilot CLI | dev | available through `sidemesh setup --dev` |
| Fake test provider | dev | deterministic contract-testing adapter |

Run `sidemesh setup --dev` to expose the development-only providers in the setup
wizard.

## Quick start

Requirements:

- Node.js `>= 22.5.0`
- A user-managed Node install such as Homebrew, `nvm`, or Volta if you want
  `npm install -g` to work without `sudo`
- Flutter, if you want to run the app locally
- A trusted network such as Tailscale or a private LAN

Install the default Codex path:

```bash
npm install -g sidemesh @openai/codex

sidemesh up
```

From the repo instead, for development:

```bash
git clone https://github.com/mukhtharcm/sidemesh.git
cd sidemesh
npm install
npm run build
npm link
```

What that command does:

1. Persists a default config to `~/.sidemesh/config.json` if you do not have one yet.
2. Auto-detects ready providers on your machine and defaults to Codex when it is ready.
3. Checks the selected provider enough to catch obvious command problems before launch.
4. Launches the daemon in the background.
5. Prints the host URL, token, and QR code for the app.

Use `sidemesh setup` when you want to customize providers, host features, or advanced settings before starting the daemon.

For foreground development instead of a managed background daemon:

```bash
npm run setup
npm run daemon
```

## Connecting the app

Open the app, then either use the QR code printed by `sidemesh up`, run
`sidemesh pair`, or add the host manually with:

- a label
- a base URL such as `http://100.x.x.x:8787` or `http://192.168.x.x:8787`
- the shared bearer token

To run the Flutter app locally:

```bash
cd apps/mobile
flutter pub get
flutter run --flavor dev -t lib/main.dart
```

Platform-specific app notes live in `apps/mobile/README.md`.

## Common commands

| Command | Purpose |
| --- | --- |
| `sidemesh up` | create a default config if needed, start the daemon, and print pairing details |
| `sidemesh setup` | customize the persisted config |
| `sidemesh doctor` | run startup and provider diagnostics |
| `sidemesh status` | show resolved config and local daemon health |
| `sidemesh pair` | print host details and QR code |
| `sidemesh daemon` | run the daemon in the foreground |
| `sidemesh start` | run the daemon in the background |
| `sidemesh stop` | stop the managed daemon |
| `sidemesh restart --yes` | restart without prompting |
| `sidemesh service install` | install the OS service wrapper |
| `sidemesh service status` | show systemd or launchd status |

On Linux, `sidemesh service install` uses systemd and typically needs `sudo`. On
macOS, it installs a user LaunchAgent instead.

## Development

Server checks:

```bash
npm run typecheck
npm run test:server
npm run build
```

Flutter checks:

```bash
cd apps/mobile
flutter test
flutter analyze
```

Useful repo scripts:

```bash
npm run mobile:get
npm run test
npm run secret:scan
```

## Security model

Sidemesh is for trusted networks only. Do not expose the daemon directly to the
public internet.

Current auth is a shared bearer token:

- all `/api/*` HTTP routes and websocket endpoints require `Authorization: Bearer <token>`
- `GET /healthz` is intentionally unauthenticated for local health checks
- per-device token revocation is not implemented yet

Host-side features such as integrated terminals, port forwarding, and browser
preview should stay disabled unless you intentionally need them.

## More documentation

- `docs/getting-started.md`
- `docs/provider-adapter-contract.md`
- `CONTRIBUTING.md`
- `docs/release-playbook.md`
