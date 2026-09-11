# ACP support matrix

This matrix applies to `@agentclientprotocol/sdk` **1.4.0** and ACP protocol
**1**. The adapter imports the stable package entry point. SDK and protocol
version numbers are different. An SDK export does not by itself make a method
stable or enable it in Sidemesh.

## Production contract

| Area | Sidemesh behavior | Capability or condition |
|---|---|---|
| Initialization | SDK validation, JSONL framing, explicit version check | Protocol version 1 only |
| Process ownership | Explicit executable and arguments; legacy shell commands remain compatible | Owned child process; 16 MiB maximum protocol line; request timeouts |
| Idle connections | Close after ten idle minutes; retain saved sessions | Active requests, prompts, and pending user input prevent idle close |
| Agent authentication | Select the exact advertised method; call `authenticate` | Agent-managed method |
| Terminal authentication | Run the same configured executable with added arguments and environment; require exit 0 | Explicit executable and host terminal service |
| Environment credentials | Inherit the agent launch environment; remove `SIDEMESH_TOKEN` | Agent owns its credential interpretation |
| Logout | User action, idle check, close connections after success; retain history | `agentCapabilities.auth.logout` |
| New session | Create native session and retain stable local identity | Base protocol |
| List | Follow opaque cursors on an existing connection | `sessionCapabilities.list` |
| Load | Stage replay and replace history only after success | `loadSession` |
| Resume | Resume without claiming history replay | `sessionCapabilities.resume` |
| Close | Notify the agent before closing the owned connection | `sessionCapabilities.close` |
| Delete | Native deletion before local removal; separate from archive | `sessionCapabilities.delete` |
| Text and references | Text, local file references, and URI references | Base content contract |
| Images | Local images and image data URLs | `promptCapabilities.image` |
| Audio | Base64 audio with MIME type | `promptCapabilities.audio` |
| Embedded resources | Text or base64 binary content with URI | `promptCapabilities.embeddedContext` |
| Input delivery | Host durable queue; preserve client input identity | No claimed ACP steering support |
| Output | Text, thoughts, tool IDs and partial updates, media, diffs, terminal references | Shared transcript and activity contract |
| Plans and commands | All plan entries; current command catalog; command text through prompt | Advertised session updates |
| Configuration | Select and boolean controls; supported mode compatibility path | Advertised options and current values |
| Permission requests | Exact selected option ID; cancel on disconnect | No broader approval substituted for a missing option |
| Filesystem | Canonical workspace paths, size limits, approval and write conflict check | Declared client file capabilities |
| Terminals | Create, output, wait, kill, release; session ownership and bounded output | Declared client terminal capability |
| Elicitation | Validated form and URL requests; cancellation and completion | Declared client elicitation capabilities |
| Compaction updates | Status and summary display | Declared client compaction update support |
| Extension metadata | Retain opaque `_meta` maps at source paths on messages, tools, and stored session metadata | Preserved through replay; never interpreted as host permissions |
| Recovery | Keep unconfirmed local output; commit complete native replay atomically | SQLite display and recovery records |

Inline input content is limited to 5 MiB per item. Resource URI values do not
cause Sidemesh to fetch a URL or read a host path. Agent-generated references
remain untrusted data. ACP capabilities describe protocol support; they do not
provide an operating-system sandbox for the agent process.

## Draft and optional extensions

| Surface | Status in this version | Sidemesh selection |
|---|---|---|
| ACP v2 | Draft; separate SDK `experimental/v2` export | Not enabled; version 2 is rejected |
| `session/fork` | SDK marks request and capability **UNSTABLE** | Not enabled or advertised |
| MCP over ACP / proxying | Optional extension contract | Not enabled; no generic RPC tunnel |
| Document synchronization | Unstable document methods in SDK | Not enabled or advertised |
| Next edit suggestions | Unstable NES capability and methods | Not enabled or advertised |
| Provider configuration methods | Unstable `providers` capability | Not enabled; session configuration remains supported |
| Former `env_var` authentication | Removed from the selected protocol types | Not implemented; use agent or terminal authentication |

Agent-owned MCP configuration remains with the agent. Sidemesh sends an empty
additional MCP server list when it creates, loads, or resumes an ACP session.
Adding proxy, document, fork, or edit-suggestion support requires a named version,
an explicit feature selection, capability checks, and protocol tests.

The pinned SDK source marks `SessionForkCapabilities` and `ForkSessionRequest`
as unstable. The upstream authentication proposal records removal of `env_var`;
it must not be reconstructed from older examples. See the versioned
[SDK source](https://github.com/agentclientprotocol/typescript-sdk/tree/v1.4.0)
and [authentication proposal](https://github.com/agentclientprotocol/agent-client-protocol/blob/main/docs/rfds/auth-methods.mdx).

## Checks and limits

`src/acp-provider.test.ts` uses SDK connections to check the request boundary,
capability negotiation, native ID handling, history replay, authentication,
cancellation, media input, and owned-process cleanup. `src/acp-host.test.ts`
checks delegated operations and exact permission choices. Server tests check
HTTP authentication, input gates, and host recovery. Client tests check controls
and content in light and dark modes on desktop and mobile layouts.

For an installed agent, set `SIDEMESH_TEST_ACP_EXECUTABLE` and optional JSON-array
`SIDEMESH_TEST_ACP_ARGS`, then run
`node --import tsx --test src/acp-native.test.ts`. This check uses temporary native
homes and sends no prompt. It checks an empty session or the explicit sign-in
requirement, plus version negotiation and owned-process cleanup. The Codex ACP
bridge `0.0.44` was checked with Codex `0.154.0` through its `CODEX_PATH` setting.

These checks do not certify all releases of third-party ACP agents. Install a
specific agent version and run its separate compatibility checks before changing
a production launch entry. Opening saved session history does not install an
agent or select a new bridge release.
