# Getting Started with Sidemesh

Sidemesh is a fleet-first mobile control plane for agent sessions. It lets you
drive multiple coding agents (Codex, Pi, Copilot) from a single mobile or
desktop app, with the daemon running on your development machines.

## What You Need

- **Host machine** (where you code): macOS, Linux, or Windows with WSL
  - Node.js 20+
  - For Pi provider: Pi must be installed separately
- **Client device**: iOS, Android, macOS, or Linux
  - Flutter runtime for the mobile app
- **Network**: Tailscale, private LAN, or localhost

## Install the Daemon

### From source (recommended for development)

```bash
git clone https://github.com/mukhtharcm/sidemesh.git
cd sidemesh
npm install
npm run build
npm link              # makes sidemesh available globally
```

### From private GitHub repo

```bash
npm install -g github:mukhtharcm/sidemesh
```

## First-Time Setup

Run the interactive setup wizard:

```bash
sidemesh setup
```

This writes ~/.sidemesh/config.json with:
- Shared bearer token for client authentication
- Selected agent provider(s)
- Daemon port and label

### Provider-specific prerequisites

| Provider | Extra setup |
|----------|-------------|
| **Codex** (default) | Install codex CLI: npm install -g @openai/codex |
| **Pi** | Install Pi: npm install -g @mariozechner/pi-coding-agent, then pi /login |
| **Copilot** | Install GitHub Copilot CLI and authenticate |
| **Fake** | No extra setup; for testing only (--dev flag) |

## Start the Daemon

### Background mode (recommended)

```bash
sidemesh start       # detached background daemon
sidemesh pair        # print QR code + connection details
```

### Foreground mode (for debugging)

```bash
sidemesh daemon      # runs in terminal, shows live logs
```

### As a system service

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

## Connect the Mobile App

### Option 1: QR code (fastest)

1. Run sidemesh pair on the host
2. Open the Sidemesh app
3. Tap the host editor -> Scan QR
4. Point camera at the terminal QR code

### Option 2: Manual entry

1. Run sidemesh pair to see the base URL and token
2. In the app, tap Add host manually
3. Enter:
   - **Label**: any friendly name (e.g., MacBook, lab-vps)
   - **Base URL**: http://HOST:PORT (shown by sidemesh pair)
   - **Token**: the bearer token from sidemesh pair

Example URLs:
- Tailscale: http://100.94.10.20:8787
- LAN: http://192.168.1.50:8787
- Localhost: http://localhost:8787

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

1. **Start daemon** on host: sidemesh start (or let the service auto-start)
2. **Open app** on phone/desktop
3. **Select host** from the host list
4. **Create or resume** a session
5. **Chat** with the agent -- tools, file changes, and terminal output stream live

## Useful Commands

| Command | Purpose |
|---------|---------|
| sidemesh setup | Re-run config wizard |
| sidemesh doctor | Check provider health and connectivity |
| sidemesh status | Show config, PID, and health |
| sidemesh pair | Re-print connection QR/code |
| sidemesh stop | Stop background daemon |
| sidemesh restart --yes | Restart daemon non-interactively |
| sidemesh service status | Check OS service state |

## Troubleshooting

**No providers configured**
Run sidemesh setup and select at least one provider.

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
- Check release-playbook.md for cutting preview builds
