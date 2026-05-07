# Pi Provider -- Getting Started

The Pi provider lets Sidemesh drive Pi sessions directly through its TypeScript SDK. Unlike the Codex and Copilot adapters, which shell out to external CLIs, the Pi provider runs Pi in-process.

## Prerequisites

1. Pi must be installed and configured independently.
   The provider does not install or authenticate Pi for you.

   ```bash
   npm install -g @mariozechner/pi-coding-agent
   pi /login          # authenticate with your provider
   pi /model          # pick a default model
   ```

   Pi stores credentials in ~/.pi/agent/ by default.

2. Node.js 22.5+ -- same requirement as the Sidemesh daemon.

## Sidemesh Setup

### Guided setup

```bash
npm install -g sidemesh @mariozechner/pi-coding-agent
sidemesh setup         # select Pi from the provider list
sidemesh up
```

### Manual config

Add to ~/.sidemesh/config.json:

```json
{
  "providers": [
    {
      "kind": "pi",
      "agentDir": "~/.pi/agent",
      "stateDir": null
    }
  ],
  "defaultProviderKind": "pi"
}
```

| Field | Description |
|-------|-------------|
| agentDir | Pi config directory. Default: ~/.pi/agent |
| stateDir | Sidemesh Pi sidecar state. Default: ~/.sidemesh/pi-provider |

## Capabilities

| Feature | Status | Notes |
|---------|--------|-------|
| Text input | yes | Full support |
| Local images | yes | Base64-encoded |
| Image URLs | no | Ignored with warning |
| Skills | yes | Inlined from Pi skill dirs |
| Model switching | yes | Auth-filtered model list |
| Thinking level | yes | Override when supported |
| Compaction | yes | Native Pi compaction |
| Session archive | yes | Sidecar tracked |
| Interrupt | yes | Calls Pi abort() |
| Filesystem | no | Host-owned |
| Approvals | no | Pi does not expose gating |
| Terminal | no | Host-owned |

## Environment Variables

| Variable | Purpose |
|----------|---------|
| SIDEMESH_PI_AGENT_DIR | Override Pi agent directory |
| SIDEMESH_PI_STATE_DIR | Override Sidemesh sidecar directory |

## Troubleshooting

**Unknown Pi session after restart**
The sidecar index is stale. Restarting triggers a fresh scan of ~/.pi/agent/sessions/.

**No API key for anthropic/claude-**
The model is visible but unauthenticated. Run pi /login for that provider.

**Image URLs silently ignored**
Pi only accepts local files. Sidemesh emits a stderr warning and substitutes an explanatory prompt.

**Slow session list**
First scan walks all .jsonl files. Subsequent calls use a stat-based fingerprint cache.
