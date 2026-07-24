# Getting Started with Sidemesh

Sidemesh is a fleet-first mobile control plane for agent sessions. It lets you
drive multiple coding agents (Codex, Pi, Copilot, ACP-compatible agents via
acpx) from a single mobile or desktop app, with the daemon running on your
development machines.

## What You Need

- **Host machine** (where you code): macOS, Linux, or Windows with WSL
  - Node.js 22.19+
  - A user-managed Node install such as Homebrew, nvm, or Volta if you want
    `npm install -g` to work without sudo
  - For Pi provider: Pi must be installed separately
- **Client device**: iOS, Android, macOS, or Linux
  - Flutter runtime for the mobile app
- **Network**: Tailscale, private LAN, or localhost

## Install the Daemon

### From npm (recommended)

For the default Codex path:

```bash
npm install -g sidemesh @openai/codex
```

### From source (recommended for development)

```bash
git clone https://github.com/mukhtharcm/sidemesh.git
cd sidemesh
npm install
npm run build
npm link              # makes sidemesh available globally
```

## First-Time Setup

For the default Codex path, one command is enough:

```bash
sidemesh up
```

This will:
- Create `~/.sidemesh/config.json` if it does not exist yet
- Auto-detect ready providers on the machine and default to Codex when it is ready
- Start the daemon in the background
- Print the base URL, token, and pairing QR code

Use `sidemesh setup` when you want to customize providers, host features, or advanced settings before starting.

### Provider-specific prerequisites

| Provider | Extra setup |
|----------|-------------|
| **Codex** (default) | Install codex CLI: npm install -g @openai/codex |
| **Pi** | Install Pi: npm install -g @earendil-works/pi-coding-agent, then pi /login |
| **Copilot** | Install GitHub Copilot CLI and authenticate |
| **ACP via acpx** | Install/authenticate the selected ACP agent (for example Gemini, Claude, Qwen, Cursor, or Kimi) |
| **Fake** | No extra setup; for testing only (--dev flag) |

## Start the Daemon

### Background mode (manual)

```bash
sidemesh up          # create config if needed, start, and print pairing details
```

Use this if you want Sidemesh running in the background without setting up a
service. The app can connect normally, but if you use Restart or Update in the
app, you may need to start Sidemesh again yourself.

### Foreground mode (for debugging)

```bash
sidemesh daemon      # runs in terminal, shows live logs
```

Closing the terminal stops the daemon. Use this mode when you want live logs
and do not mind starting it again yourself.

### As a system service (recommended for day-to-day use)

**Linux (systemd):**
```bash
sudo sidemesh service install
sudo sidemesh service restart --yes
```

**macOS (LaunchAgent):**
```bash
sidemesh service install      # no sudo needed
sidemesh service restart --yes
```

Use this if you want the app's Restart and Update buttons to bring the host
back on their own.

## Connect the Mobile App

### Option 1: QR code (fastest)

1. Use the QR code printed by sidemesh up, or run sidemesh pair on the host
2. Open the Sidemesh app
3. Tap the host editor -> Scan QR
4. Point camera at the terminal QR code

### Option 2: Manual entry

1. Use the base URL and token printed by sidemesh up, or run sidemesh pair again
2. In the app, tap Add host manually
3. Enter:
   - **Label**: any friendly name (e.g., MacBook, lab-vps)
   - **Base URL**: http://HOST:PORT (shown by sidemesh pair)
   - **Token**: the bearer token from sidemesh pair

Example URLs:
- Tailscale: http://100.94.10.20:8787
- LAN: http://192.168.1.50:8787
- Localhost: http://localhost:8787

Pairing codes can advertise multiple Tailscale, LAN, IPv6, hostname, and
loopback addresses. The app tests them from the client device and saves a
reachable address instead of assuming the host's first choice works on every
network.

## In-App Restart and Update

From the host details screen, you can choose an update channel, restart the
daemon, and run self-update.

- **Stable** gets tagged releases.
- **Bleeding edge** gets the newest commits on `main` for local repo installs.
- If you want the app's Restart and Update buttons to work reliably, use
  `sidemesh service install`.
- If you run `sidemesh daemon`, `sidemesh start`, or `sidemesh up`, update and restart it
  yourself when needed.

### Build the app

```bash
cd apps/mobile
flutter pub get
flutter run --flavor dev
```

Or install a debug APK:

```bash
cd apps/mobile
flutter build apk --debug
flutter install --debug -d DEVICE_ID
```

## Daily Workflow

1. **Start daemon** on host: sidemesh up for most manual runs, or let the OS
   service auto-start
2. **Open app** on phone/desktop
3. **Select host** from the host list
4. **Create or resume** a session
5. **Chat** with the agent -- tools, file changes, and terminal output stream live

## Useful Commands

| Command | Purpose |
|---------|---------|
| sidemesh up | Create a default config if needed, start the daemon, and print pairing details |
| sidemesh setup | Customize providers, host features, and advanced settings |
| sidemesh doctor | Check provider health and connectivity |
| sidemesh status | Show config, PID, and health |
| sidemesh pair | Re-print connection QR/code |
| sidemesh stop | Stop background daemon |
| sidemesh restart --yes | Restart a daemon started with `sidemesh start` or `sidemesh up` |
| sidemesh service restart --yes | Restart the OS service on macOS/Linux |
| sidemesh service status | Check OS service state |

## Troubleshooting

**No providers configured**
Run sidemesh up for the default Codex path, or sidemesh setup and select at least one provider.

**npm install -g fails with EACCES**
Use a user-managed Node install such as Homebrew, nvm, or Volta, or configure
an npm prefix in a user-writable directory before retrying the global install.

**Unsupported engine or node:sqlite error**
Upgrade Node to 22.5 or newer, then rerun the install. Node 20 is not
supported by the published package.

**Port already in use**
Another Sidemesh daemon is running. Run sidemesh status to find it, or use
--allow-duplicate if you genuinely need two daemons.

**Unknown provider: pi**
The daemon was built before the Pi provider was added. Rebuild:
npm run build && npm link

**Mobile app shows Connection failed**
- Verify the host and client are on the same network (or Tailscale)
- Check sidemesh status shows healthy
- Verify the token matches exactly
- Try the raw URL in a browser: http://HOST:PORT/healthz

**App says the daemon is restarting or updating, but the host does not come back**
- This works best when Sidemesh is installed as a background service on macOS
  or Linux
- If you started it with `sidemesh daemon`, `sidemesh start`, or `sidemesh up`, start it again
  yourself or switch to `sidemesh service install`

**Pi model list is empty**
Pi has no authenticated providers. Run pi /login for your model provider
(e.g., Anthropic, OpenAI).

## Security Notes

- Keep the daemon on trusted networks only (Tailscale, private LAN)
- The shared token is stored in platform secure storage on the client
- Token revocation is not yet implemented -- rotate the token in
  ~/.sidemesh/config.json if a device is lost
- Do not expose the daemon port to the public internet

## Next Steps

- Read the provider adapter contract to understand how capabilities map to UI features
- See Pi provider getting started for Pi-specific setup and capabilities
- See ACP via acpx provider getting started for ACP-compatible agent setup
- Check release-playbook.md for cutting preview builds
