# Provider Adapter Contract

Sidemesh currently ships with a production Codex adapter, a supported Pi
adapter, dev-only OpenCode and GitHub Copilot adapters, and an in-process fake
test adapter. The daemon is structured so future agents can be added behind the
same host/session API.

## Entry Points

- Register provider metadata and config loading in `src/provider-registry.ts`.
- Construct the provider through `src/provider-factory.ts`.
- Implement the provider contract in `src/agent-provider.ts`.
- Keep provider-specific protocol translation inside the adapter file, like
  `src/codex-provider.ts`.
- Use `src/fake-provider.ts` as the deterministic contract harness when adding
  or testing provider-neutral app behavior.

## Runtime Selection

`AgentProviderRuntime` is the provider registry and selection layer. Server
routes should ask it for the default provider, a requested catalog provider, or
the provider that owns a namespaced session id.

The runtime holds a direct instance map and starts each adapter when needed.
It does not implement `AgentProvider`. Routes resolve the configured entry and
native session ID, then call that adapter. Capabilities remain specific to each
instance. A provider failure leaves host health and controls available. The
provider endpoints expose `idle`, `starting`, `ready`, `unavailable`, and `closed`
states. Host restart recreates one instance and closes its old connections.

Public IDs use `instanceId:base64url(nativeId)`, including single-provider hosts.
SQLite saves legacy raw ownership and kind aliases. Changing the default or
removing an instance cannot transfer its sessions. Host input records, plans,
and recovery are migrated together; a conflict preserves the source records
and aborts the transaction. Old callers can use their saved aliases. HTTP and
live responses retain the requested alias and expose `canonicalSessionId`.
`sessionAliases` in the provider metadata supports client cache migration.
The client saves that ownership map for offline use. It migrates cached session
rows and logs in a database transaction, combines favorite flags, and retains
provider instance IDs. Saved controls, pins, read state, and inspector choices
resolve old keys through the same map. Pending sends retain their original
session and client input IDs; lookup and removal accept equivalent aliases.
An ownership change cannot reassign an existing client alias to another agent.

## Required Core

Every provider must implement:

- `kind`: stable provider id, for example `codex`.
- `displayName`: human-readable provider name.
- `capabilities`: feature flags used by the app to hide unsupported UI.
- `start()`: boot or connect to the local agent service.
- `getVersion()`: return the provider CLI/service version if available.

All other methods are optional and must match the advertised capability flags.
If a provider does not support a feature, leave the method undefined and set the
capability to `false`.

## Capability Groups

Session history:

- `listSessionThreads`
- `readSessionThread`
- `readSessionSnapshot`
- `readSessionLog`
- `readSessionRuntime`
- `listRecentUnindexedSessionThreads`

`listSessionThreads` treats spawned child sessions as provider-owned agent
runs, not peer history rows. Normal history calls omit them. Callers that need
the Agents surface set `includeSubAgents` and `subAgentParentId`; adapters must
paginate until they satisfy the parent-scoped limit or exhaust history.
The host resolves the parent owner before dispatch and namespaces both the child
and parent IDs on return. The daemon exposes the normalized result at
`GET /api/sessions/:sessionId/agent-runs`.

Session lifecycle:

- `createSession`
- `submitInput`
- `listLoadedSessionIds`
- `resumeSessionThread`
- `setSessionName`
- `archiveSession`
- `unarchiveSession`
- `interruptTurn`

`SessionCoordinator` owns the published view and its `SessionInputCoordinator`
serializes host input dispatch. It saves queue payloads
and receipts in SQLite. An adapter that cannot accept input while busy sets
`input.steer` to `false`; the host returns `mode: "queued"` after saving the
request. Only known unsent rows can run automatically after restart. Native
acceptance does not confirm execution or durable history. Unknown sends keep
their payload and return `input_delivery_uncertain` on retry. Stop and archive
cancel queued rows before interruption; daemon shutdown retains those rows.
Adapters can set `AgentProviderRequestError.inputNotDispatched` only when the
prompt was never sent.

The create route creates an empty native session, then saves and dispatches its
first input through the same queue. If this dispatch fails, the error response
includes the created session and client input ID. An input receipt cannot start
or restore a turn. `interruptTurn` can receive a null turn ID: use native session
cancellation when available, or report that a native turn ID is required.

`readSessionSnapshot` returns one complete normalized native view, including
`thread`, `busy`, `activeTurnId`, and any `confirmedInputIds` backed by native
proof. Busy work need not have a turn ID. The host serializes snapshot reads for
each session and applies client limits after recovery reconciliation. It uses
this path for logs, status, resources, and input dispatch. Only execution and
runtime events received during the read can override the returned native state.

The coordinator saves unconfirmed messages, drafts, and tool updates in SQLite
`session_recovery` before publishing them. A failed read, turn completion,
provider restart, or new turn does not discard that content. A matching native
item must cover its content before removal. Recovered drafts remain display
content until a new native event makes them live. Provider listeners stay
attached through shutdown so final output reaches this store.

Approvals:

- `respondToPendingAction`

Configuration:

- `setSessionConfiguration` (requires `configuration.sessionOptions`)
- `listModels`
- `listProfiles`
- `listAccessModes`
- `listPermissionProfiles` (legacy compatibility)
- `listSkills`
- `writeSkillConfig`

`GET /api/sessions/:id/configuration` returns the current runtime options.
`POST` on the same path applies one advertised `optionId` with a string or
boolean `value`. The adapter validates the offered values and returns the
confirmed runtime. The client keeps failed edits for retry and preserves option
groups and descriptions. These controls replace fixed settings for providers
that advertise `configuration.sessionOptions`.

Access modes are provider-owned execution policies, not aliases for the
daemon's workspace filesystem boundary. A provider that advertises
`configuration.accessModes` returns display-ready choices with opaque IDs,
labels, descriptions, semantic icon and tone hints, availability, optional
confirmation copy, and a current default. It must also advertise
`runtimeControls.accessMode` before accepting the selected ID on create or
submit.

Shared clients must not reconstruct provider semantics from an access-mode ID
or receive the native permission tuple behind it. The selected adapter validates
and translates the opaque ID immediately before calling its provider. Provider
configuration, managed restrictions, and dangerous choices therefore remain
truthful without teaching the Flutter app about one provider's wire protocol.

`listPermissionProfiles`, `runtimeControls.permissionProfile`, and
`runtimeControls.approvalsReviewer` remain temporarily for compatibility with
older Sidemesh clients. New provider-neutral UI should use access modes and keep
host filesystem scope separate from provider execution access.

Approval requests may include provider-defined response options. Adapters must
preserve the provider's option IDs and labels, map each option to one of the
portable `allow_once`, `allow_always`, `reject_once`, or `reject_always` kinds,
and route the selected ID back to the provider unchanged. Generic approval
scopes remain a compatibility fallback for providers that do not expose native
options.

Model summaries should describe UI behavior without requiring the Flutter app
to inspect provider-specific model names:

- `reasoningEffortControl: "client"` means the UI may send an explicit
  reasoning effort override when supported.
- `reasoningEffortControl: "provider"` means the provider/model owns the
  reasoning choice, so the UI should present it as auto/provider-managed and
  avoid sending a reasoning override.
- `sortOrder` is optional provider-owned display ordering. Lower values sort
  earlier; missing values fall back to profile models before ordinary models.

Workspace:

- `readRemoteGitDiff`

Local git status, local working/staged/unstaged diffs, integrated terminals, and
browser tabs are daemon-owned host features. Providers only own
`readRemoteGitDiff`, because that may require agent/provider-specific context.
Local filesystem browse/read/write/watch is also daemon-owned and implemented
in `src/fs-routes.ts`; do not add local filesystem methods to
`AgentProvider`, and do not advertise local filesystem support through provider
capabilities.

## Runtime Events

Providers should emit `liveEvent` events for streaming UI updates:

- `turn_started`
- `assistant_delta`
- `assistant_message_completed`
- `activity_updated`
- `activity_output_delta`
- `activity_terminal_input`
- `turn_completed`
- `action_opened`
- `skills_changed`

> **Note:** `fs_changed` is no longer emitted by provider adapters. Host-owned
> filesystem watches in `src/fs-routes.ts` send `fs_changed` directly over the
> WebSocket. Provider adapters should not implement filesystem operations.

Provider adapters should translate native agent events into Sidemesh activity
types instead of leaking provider-specific wire payloads to the Flutter app.
Image-bearing tool results belong on provider-neutral `ToolActivity.attachments`.
Adapters may populate those attachments directly; the shared activity
normalizer also recognizes common OpenAI, MCP, and ACP image content blocks.
After promotion, inline image data is removed from the raw tool `result` so the
client does not cache or render the same base64 payload twice.

## HTTP Behavior

Server routes check both capability flags and method presence. A provider that
does not support a provider-owned route should produce a `501` instead of
forcing every adapter to implement Codex-only methods. Daemon-owned features
such as local git status, terminals, and browser tabs are exposed through
`hostCapabilities`.

Compatibility shims are acceptable only when a provider already exposes a
native concept but its current server/runtime integration fails to restore or
surface it correctly. Track those shims in `BACKLOG.md`, keep them narrow, and
prefer migrating back to the provider's native solution once it becomes
reliable upstream.

Metadata endpoints:

- `/api/node` exposes the active provider, provider version,
  `defaultProviderCapabilities`, `hostCapabilities`, and supported provider
  metadata with per-provider capability maps.
- `/api/providers` exposes daemon-supported provider definitions for future
  provider-selection UI.
- There are no `providerCapabilities` or `codexVersion` aliases.
- Session refreshes use the adapter's `readSessionSnapshot` implementation. The host
  does not parse provider files through a separate replay index. See
  [session synchronization](session-synchronization.md).

## Adding The Next Provider

1. Add provider config types to `src/types.ts`.
2. Add a provider definition to `src/provider-registry.ts`.
3. Implement a provider adapter that satisfies the required core and whichever
   optional capability groups it can honestly support.
4. Set unsupported capabilities to `false` first, then enable them one by one.
5. Add client UI only after the provider capability map is accurate.

The fake provider can be run with `SIDEMESH_PROVIDER=fake npm run daemon`. It
supports all current capability groups and uses prompt keywords to trigger
repeatable app states:

- `tools`: command output, terminal input, file change, turn diff, and web search.
- `tool-attachment`: the tooling scenario with a provider-neutral image
  attachment on its completed tool activity.
- `approval:command`, `approval:file`, `approval:permissions`: pending actions.
- `image`: image generation activity.
- `slow`: delayed streaming.
- `fail`: failed turn completion.

`SIDEMESH_FAKE_CAPABILITY_PROFILE` narrows the advertised capability set for
dogfooding non-Codex behavior before a real adapter exists. Supported profiles
are `full`, `chat-only`, `no-files`, `no-model-controls`, `no-approvals`, and
`minimal`.

The Copilot adapter is the first real non-Codex slice. It uses the GitHub
Copilot SDK for session discovery, transcript replay, turns, model controls,
permission requests, and tool execution events. It intentionally does not read
Copilot's on-disk session files directly and does not ship a hand-written model
catalog; model controls are advertised from SDK `listModels()` metadata, with
explicit host defaults layered on top when configured. Images and richer native
tool translation should be enabled only when the adapter can report honest
capabilities and translate SDK events into Sidemesh event types. The Copilot
adapter uses `auto` as the Sidemesh default for
app-started turns, so a costly persistent Copilot setting is not consumed by
accident.
