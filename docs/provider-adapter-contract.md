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
- `readSessionLogPage` (optional additive paging support)
- `readSessionRuntime`
- `listRecentUnindexedSessionThreads`

`readSessionLogPage` pages one unified chronological stream of messages and
activities. Its `limit` is the combined entry count, not a separate allowance
for each record type. Providers own the opaque, session-scoped backward cursor;
the daemon and client must not interpret it. A cursor identifies the immutable
entry immediately after the requested older page, so appending newer entries
does not move an existing boundary. Invalid cursors fail closed instead of
silently returning the newest page.

Backward history cursors and forward replay cursors are deliberately separate.
Provider `SessionLogSnapshot.nextSeq` is the exclusive next-unused transcript
sequence. Message and activity rows share this one sequence namespace, and a
provider must not assign the same `seq` to two distinct transcript rows. The
HTTP log response preserves that baseline as `nextSeq`; clients
subtract one to obtain the inclusive `since` cursor used by event replay. The
host may also return a larger exclusive `replayNextSeq` when it has rebased
live-only activity updates above persisted history. Clients must immediately
catch up in that case. By contrast, `SessionEventsDelta.nextSeq` is the highest
inclusive replay sequence applied by that delta. None of these values may be
used as a `beforeCursor`. Providers that do not implement page reads continue
to serve the legacy bounded `readSessionLog` response without page metadata.

New clients opt into bounded forward replay with `GET .../events?page=true`.
Such responses may set `hasMore: true`; the client must keep requesting from
that response's inclusive `nextSeq` until `hasMore` is false, even if a newer
WebSocket event advances its in-memory high-water mark during the drain. The
opt-in preserves compatibility with older clients, which receive the original
`stale_cursor` response for an oversized gap and recover through their legacy
authoritative snapshot path. One indivisible event may exceed the byte target
so a paged replay can always make forward progress.

The paging contract bounds daemon-to-client payloads and client-side retained
history. It does not by itself guarantee provider-native source paging: an
adapter may still need to scan or fetch its underlying transcript to construct
a page. Adapters should use native cursors, byte-offset indexes, or incremental
persistent indexes when their source supports them, and must document when the
source API only offers full-history reads.

Current adapter limitations are explicit:

- Codex streams the rollout JSONL from the beginning for a cold head read and
  retains bounded result rows, but older pages currently reconstruct the full
  normalized transcript before slicing.
- OpenCode's current `listMessages` API returns the full message collection;
  page construction happens after that fetch.
- Copilot, Pi, and ACPX expose or hydrate complete provider session state before
  Sidemesh applies its page boundary.
- The fake provider pages its in-memory deterministic transcript.

Consequently, this contract reduces wire size, JSON decoding, widget work, and
client/cache growth today. Provider-native or persistent source indexes remain
required to make cold initial reads and long backward walks sublinear.

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
