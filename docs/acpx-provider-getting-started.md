# ACP provider

Use a native Sidemesh provider when one is available. The ACP provider uses the
official `@agentclientprotocol/sdk` for agents that need the Agent Client Protocol.
The stored provider kind remains `acpx` so existing configuration and session links
continue to work. Sidemesh no longer embeds the ACPx runtime.

## Setup

Run `sidemesh setup`, select **ACP**, then select an agent or enter a custom command.
Install and sign in to the selected agent. Sidemesh can also show agent-managed
sign-in choices and ACP form or URL requests in the app.

```bash
SIDEMESH_PROVIDER=acpx
SIDEMESH_ACPX_AGENT=gemini
SIDEMESH_ACPX_COMMAND=        # optional command override
SIDEMESH_ACPX_STATE_DIR=      # optional legacy history directory
SIDEMESH_ACPX_PERMISSION_MODE=approve-reads
```

- `approve-reads` permits ACP read/search requests only when the agent offers an
  `allow_once` choice. Other permission requests appear in the app. The selected
  option ID is returned unchanged.
- `deny-all` cancels permission requests and denies delegated file and command
  operations.

Delegated file access stays inside the session workspace after symbolic links
are resolved. File writes require app approval and are rejected if the target
changes while approval is pending. Commands require app approval. Sidemesh owns
terminal output, cancellation, and cleanup. These controls do not sandbox the
agent process itself.

## Sessions and saved data

The host's `sessions-v1.db` stores ACP session identity, local names and archive
choices, and required display history. Old ACPx records are imported once from
`<legacy-directory>/sessions`. The import keeps session IDs and original files.
Changing the launch command does not hide imported history.

A successful `session/load` response completes a staged history replay. A failed
replay keeps the previous data. Local output remains until native history
confirms it. `session/resume` does not imply a history replay. For agents with no
history replay, the local display transcript is required data.

Listing stored sessions and archiving them do not launch or download an agent.
Native session discovery uses an existing connection when the agent supports
`session/list`. Each live session has its own connection, because some agents
cannot keep several active sessions on one connection.

Configure different instance `id` values to use several ACP agents, or several
instances of the same agent, in one daemon. Keep existing IDs when changing a
command. The legacy launch entries are retained for compatibility; use an explicit
command to select a different bridge version.
