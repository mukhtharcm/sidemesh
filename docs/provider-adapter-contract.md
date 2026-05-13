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

`MultiAgentProvider` is only the session aggregation/routing facade. It owns
session id namespacing, event wrapping, and session operation dispatch. It does
not advertise an OR-merged capability surface, and provider-owned catalog routes
should use concrete runtime entries instead of default-provider forwarding.

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
- `readSessionLog`
- `readSessionRuntime`
- `listRecentUnindexedSessionThreads`

Session lifecycle:

- `createSession`
- `submitInput`
- `listLoadedSessionIds`
- `resumeSessionThread`
- `setSessionName`
- `archiveSession`
- `unarchiveSession`
- `interruptTurn`

Approvals:

- `respondToPendingAction`

Configuration:

- `listModels`
- `listProfiles`
- `listSkills`
- `writeSkillConfig`

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
port forwarding are daemon-owned host features. Providers only own
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
- `session_message_appended`
- `activity_updated`
- `activity_output_delta`
- `activity_terminal_input`
- `turn_completed`
- `action_opened`
- `skills_changed`

`assistant_message_completed` and `session_message_appended` message drafts may
include provider-owned `seq` and `createdAt` values. The daemon keeps the
WebSocket event `seq` separate from the persisted transcript message `seq`, so
providers should pass through the persisted values when they have already
written the message to session history.

> **Note:** `fs_changed` is no longer emitted by provider adapters. Host-owned
> filesystem watches in `src/fs-routes.ts` send `fs_changed` directly over the
> WebSocket. Provider adapters should not implement filesystem operations.

Provider adapters should translate native agent events into Sidemesh activity
types instead of leaking provider-specific wire payloads to the Flutter app.

## HTTP Behavior

Server routes check both capability flags and method presence. A provider that
does not support a provider-owned route should produce a `501` instead of
forcing every adapter to implement Codex-only methods. Daemon-owned features
such as local git status, terminals, and port forwarding are exposed through
`hostCapabilities`.

Compatibility shims are acceptable only when a provider already exposes a
native concept but its current server/runtime integration fails to restore or
surface it correctly. Track those shims in `BACKLOG.md`, keep them narrow, and
prefer migrating back to the provider's native solution once it becomes
reliable upstream.

Compatibility endpoints:

- `/api/node` exposes the active provider, provider version,
  `defaultProviderCapabilities`, `hostCapabilities`, and supported provider
  metadata with per-provider capability maps.
- `/api/providers` exposes daemon-supported provider definitions for future
  provider-selection UI.
- `providerCapabilities` remains as a compatibility alias in `/api/node` for
  `defaultProviderCapabilities`. New clients should prefer
  `defaultProviderCapabilities` or `supportedProviders[].capabilities`.
- `codexVersion` remains as a compatibility alias in `/api/node`; new code
  should prefer `providerVersion`.

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
