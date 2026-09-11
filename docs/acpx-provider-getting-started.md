# ACP provider

Use a native Sidemesh provider when one is available. The ACP provider uses the
official `@agentclientprotocol/sdk` for agents that need the Agent Client Protocol.
The stored provider kind remains `acpx` so existing configuration and session links
continue to work. Sidemesh no longer embeds the ACPx runtime.

## Setup

Run `sidemesh setup`, select **ACP**, then select an agent or enter a custom command.
Install and sign in to the selected agent. Sidemesh can also show agent-managed
sign-in choices and ACP form or URL requests in the app.

Select **Executable and arguments** to launch an installed agent without a shell.
Enter the arguments as a JSON array. For example, this provider entry runs Gemini:

```json
{
  "kind": "acpx",
  "agent": "gemini",
  "executable": "gemini",
  "args": ["--acp"],
  "command": null,
  "stateDir": null,
  "permissionMode": "approve-reads"
}
```

An executable can be a path with spaces. Each argument passes unchanged; shell
variables and command substitutions are not expanded. Use either `executable`
and `args`, or the legacy `command` field. A command environment override replaces
the saved executable and arguments. The handshake records the agent name and
version. Sidemesh can show this saved version after a restart without launching
the agent. A change to the launch settings requires a new handshake.

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

When the agent advertises `session/delete`, the app offers **Delete** in session
actions and asks for confirmation. Delete removes the session from the agent's
session list, then clears the host display history and this app's cached log.
The agent controls whether it also erases its native history files. A failed
native delete keeps Sidemesh's saved history. Archive remains a local, reversible
choice and never calls native deletion. Sidemesh retains input delivery IDs to
prevent delayed retries from sending deleted input again.

Configure different instance `id` values to use several ACP agents, or several
instances of the same agent, in one daemon. Keep existing IDs when changing a
command. The legacy launch entries are retained for compatibility; use an explicit
command to select a different bridge version.
