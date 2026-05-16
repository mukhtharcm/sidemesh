# ACP via acpx provider

Sidemesh can expose ACP-compatible coding agents through the generic `acpx`
provider. This is useful for agents that speak the Agent Client Protocol but do
not have a native Sidemesh adapter yet.

## Setup

Run:

```bash
sidemesh setup
```

Select **ACP via acpx**, then choose an agent such as `gemini`, `claude`,
`qwen`, `cursor`, `kimi`, `copilot`, or `opencode`.

For custom ACP servers, choose **Custom ACP command** and provide:

- an agent id, for example `my-agent`
- an ACP command override, for example `my-agent --acp`

## Environment configuration

```bash
SIDEMESH_PROVIDER=acpx
SIDEMESH_ACPX_AGENT=gemini
SIDEMESH_ACPX_COMMAND=        # optional command override
SIDEMESH_ACPX_STATE_DIR=      # optional; defaults under ~/.sidemesh
SIDEMESH_ACPX_PERMISSION_MODE=approve-reads
```

`SIDEMESH_ACPX_PERMISSION_MODE` supports:

- `approve-reads`: auto-approve ACP read/search requests; route writes and
  commands through Sidemesh approvals.
- `deny-all`: deny ACP permission requests by default.

Sidemesh intentionally does **not** default to auto-approving writes or shell
commands.

## Notes

- The provider stores acpx session state under the configured acpx state dir.
- Session history, recent sessions, search, rename, archive, interrupt, model
  overrides, tool events, reasoning deltas, and mobile approvals are supported.
- Only one `acpx` provider instance can be configured at a time today. To expose
  multiple ACP agents concurrently, run separate Sidemesh daemons or add native
  provider-instance ids in a future config migration.
