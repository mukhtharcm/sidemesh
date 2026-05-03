# Provider Runtime Refactor Plan

This document turns the current provider-runtime study into an implementation
plan. The main goal is to make provider capability reporting honest, keep
host-owned features out of the provider contract, and preserve the parts of the
multi-provider facade that already work well: session routing, event wrapping,
and provider startup.

## Current Conclusion

At the start of the research, `AgentProviderRuntime` was not a runtime
abstraction. It was a small container that returned:

- `provider`: either a concrete provider or a `MultiAgentProvider`.
- `providers`: concrete provider entries with config and definition summaries.

Reference: `src/provider-factory.ts`

The current branch has upgraded it into a lightweight provider registry and
selection layer by adding default-provider and concrete-provider lookup helpers.
It is still intentionally not a deep provider emulator; provider-native
semantics stay inside adapters.

The real abstraction is spread across:

- `src/agent-provider.ts`: the shared provider contract and capability map.
- `src/multi-provider.ts`: the multi-provider facade and ID namespacing.
- `src/server.ts`: HTTP/WebSocket route selection and capability checks.
- Provider adapters: `src/codex-provider.ts`, `src/copilot-provider.ts`,
  `src/pi-provider.ts`, and `src/fake-provider.ts`.
- Flutter capability gates in `apps/mobile/`.

The current implementation is useful as a lowest-common-denominator UI/session
facade, but it does not accurately model what the upstream provider runtimes are.

## Implementation Status

Status as of 2026-05-03 on the `provider-runtime-refactor` branch:

- The first provider-runtime slice is implemented in PR #120.
- `/api/node` now reports `providerCapabilities` as a compatibility alias for
  `defaultProviderCapabilities`, not an OR-merged multi-provider union.
  Reference: `src/server.ts`.
- `/api/node` and `/api/providers` now include per-provider capability maps and
  provider versions. References: `src/server.ts`,
  `apps/mobile/lib/src/models.dart`, and
  `apps/mobile/test/provider_metadata_models_test.dart`.
- `AgentProviderRuntime` now exposes the default provider, concrete provider
  lookup by kind, and session-id based provider lookup. Reference:
  `src/provider-factory.ts`.
- Server catalog routes and remote Git diff selection use concrete providers
  rather than the merged session facade. Reference: `src/server.ts`.
- `MultiAgentProvider` now uses the default provider's capabilities and is
  limited to lifecycle/session aggregation, namespaced session routing, pending
  action routing, event wrapping, and stderr prefixing. Reference:
  `src/multi-provider.ts`.
- Local filesystem browse/read/write/watch is daemon-owned through
  `hostCapabilities` and `src/fs-routes.ts`; the shared `AgentProvider` surface
  no longer extends provider filesystem methods. Reference:
  `src/agent-provider.ts`.
- The adapter contract has been updated to match the landed boundary.
  Reference: `docs/provider-adapter-contract.md`.

The remaining work is no longer the basic capability/runtime split. The
remaining work is expanding the abstraction so Sidemesh can preserve richer
provider-native behavior without leaking raw Codex, Copilot, or Pi payloads to
the Flutter client.

## Source References

### Local Sidemesh References

- Core provider contract: `src/agent-provider.ts`
- Runtime construction: `src/provider-factory.ts`
- Multi-provider facade: `src/multi-provider.ts`
- Provider registry: `src/provider-registry.ts`
- Server route wiring: `src/server.ts`
- Host filesystem API: `src/fs-routes.ts`
- Host Git API: `src/git.ts`
- Host terminal API: `src/terminal.ts`
- Host port forwarding: `src/port-forward.ts`
- Host browser preview: `src/browser-preview.ts`
- Codex adapter: `src/codex-provider.ts`
- Copilot adapter: `src/copilot-provider.ts`
- Pi adapter: `src/pi-provider.ts`
- Fake provider test harness: `src/fake-provider.ts`
- Contract docs: `docs/provider-adapter-contract.md`
- Repo architecture notes: `AGENTS.md`

### Upstream Provider Source References

The study used version-matched local clones in
`/tmp/sidemesh-provider-research`. A second refresh pass was run on
2026-05-03 against the currently installed/deployed provider versions.

- Codex:
  - Installed and deployed CLI version observed during refresh:
    `codex-cli 0.128.0`.
  - Original upstream tag used: `openai/codex` `rust-v0.124.0`.
  - Refresh upstream tag used: `openai/codex` `rust-v0.128.0`
    (`e4310be51f617f5e60382038fa9cbf53a2429ca4`, 2026-04-30).
  - Protocol definitions:
    `codex-rs/app-server-protocol/src/protocol/common.rs`
  - Detailed v2 types:
    `codex-rs/app-server-protocol/src/protocol/v2.rs`
  - Python SDK wrapper:
    `sdk/python/src/codex_app_server/api.py`
  - Refresh-specific seams:
    `common.rs` includes `skills/list`, `hooks/list`, `plugin/list`,
    `plugin/install`, `fs/*`, `skills/config/write`,
    `item/tool/requestUserInput`, `mcpServer/elicitation/request`,
    `item/permissions/requestApproval`, `thread/status/changed`,
    `thread/goal/updated`, `turn/plan/updated`, reasoning deltas, warnings,
    guardian warnings, account/rate-limit updates, and external-agent import
    completion notifications.

- GitHub Copilot SDK:
  - Dependency version: `@github/copilot-sdk@0.3.0`.
  - Upstream tag used: `github/copilot-sdk` `v0.3.0` / `go/v0.3.0`.
  - Client/session creation:
    `nodejs/src/client.ts`
  - Session object and session RPC:
    `nodejs/src/session.ts`
  - Public SDK types:
    `nodejs/src/types.ts`
  - Generated session events:
    `nodejs/src/generated/session-events.ts`
  - Refresh-specific seams:
    `client.ts` registers permission, user-input, elicitation, hooks, tools,
    commands, session filesystem, model/reasoning, MCP, custom-agent, skill,
    disabled-skill, infinite-session, and token options before
    `session.create` / `session.resume`.

- Pi coding agent:
  - Dependency version: `@mariozechner/pi-coding-agent@0.71.1`.
  - Latest npm version observed during refresh: `0.72.1`. This plan still uses
    `v0.71.1` source references because that is the version locked by the repo.
  - Upstream tag used: `badlogic/pi-mono` `v0.71.1`.
  - Low-level agent core:
    `packages/agent/src/agent.ts`
  - Runtime/session core:
    `packages/coding-agent/src/core/agent-session.ts`
  - Runtime replacement:
    `packages/coding-agent/src/core/agent-session-runtime.ts`
  - Session history manager:
    `packages/coding-agent/src/core/session-manager.ts`
  - Extension model:
    `packages/coding-agent/docs/extensions.md`
  - Skill model:
    `packages/coding-agent/docs/skills.md`
  - JSON event stream:
    `packages/coding-agent/docs/json.md`
  - Refresh-specific seams:
    `agent-session.ts` defines queue, compaction, thinking-level, and auto-retry
    session events; `agent.ts` owns steering/follow-up queues; extensions can
    register tools, commands, providers, custom UI, and tool-call gates.

### Concrete Source Anchors

Local Sidemesh anchors:

- `src/provider-factory.ts:19` defines the runtime registry shape, including
  `defaultProvider`, `providerForKind()`, and `providerForSessionId()`.
- `src/provider-factory.ts:57` constructs either one concrete provider or a
  `MultiAgentProvider` session facade.
- `src/server.ts:679` builds `/api/node` with
  `defaultProviderCapabilities`, `hostCapabilities`, and per-provider
  `supportedProviders[].capabilities`.
- `src/server.ts:1494`, `src/server.ts:1528`, `src/server.ts:1571`, and
  `src/server.ts:1605` route skills, skill config, models, and profiles through
  concrete provider selection.
- `src/multi-provider.ts:65` exposes default-provider identity/capabilities
  instead of a union.
- `src/multi-provider.ts:326` wraps provider live events with namespaced
  session/action/watch IDs.
- `src/agent-provider.ts:358` documents provider-native filesystem APIs as
  outside the shared `AgentProvider` surface.
- `apps/mobile/lib/src/models.dart:112` resolves provider-scoped capabilities
  for UI gates.

Provider source anchors:

- Codex `common.rs:579` exposes `skills/list`; `common.rs:584` exposes
  `hooks/list`; `common.rs:604` exposes `plugin/list`; `common.rs:636` starts
  the `fs/*` method group; `common.rs:681` exposes `skills/config/write`.
- Codex `common.rs:1226` exposes `item/tool/requestUserInput`;
  `common.rs:1232` exposes `mcpServer/elicitation/request`;
  `common.rs:1238` exposes `item/permissions/requestApproval`.
- Codex `common.rs:1355`, `common.rs:1361`, `common.rs:1371`,
  `common.rs:1397`, and `common.rs:1404` define thread-status, thread-goal,
  plan, reasoning, and warning notifications.
- Codex `v2.rs:3922`, `v2.rs:3991`, `v2.rs:7211`, and `v2.rs:7712` define
  elicitation counters, thread goals, MCP elicitation payloads, and
  request-user-input payloads.
- Copilot `client.ts:664` creates sessions; `client.ts:681` registers a session
  before RPC so early events are not dropped; `client.ts:691` through
  `client.ts:697` register permission, user-input, and elicitation handlers.
- Copilot `client.ts:727` through `client.ts:767` serializes session create
  options, including permission/user-input/elicitation flags, streaming,
  subagent streaming, MCP, custom agents, skill directories, disabled skills,
  infinite sessions, and tokens.
- Copilot `generated/session-events.ts:6` shows the generated event union;
  `generated/session-events.ts:740`, `generated/session-events.ts:1702`,
  `generated/session-events.ts:1736`, `generated/session-events.ts:3154`,
  `generated/session-events.ts:3808`, `generated/session-events.ts:4358`,
  `generated/session-events.ts:4510`, and
  `generated/session-events.ts:4532` anchor plan, reasoning, permission,
  elicitation, capability, background-task, and skill-loaded events.
- Pi `agent-session.ts:113` defines `AgentSessionEvent`, including queue,
  compaction, thinking-level, and auto-retry events.
- Pi `agent.ts:251` through `agent.ts:318` define steering/follow-up queueing
  and active-run behavior.
- Pi `docs/extensions.md:9` lists extension capabilities, including custom
  tools, event interception, user interaction, custom UI, commands, state, and
  rendering.
- Pi `docs/extensions.md:180` through `docs/extensions.md:217` shows async
  extension startup and provider registration.
- Pi `examples/extensions/questionnaire.ts:76` and
  `examples/extensions/permission-gate.ts:13` show extension-owned custom UI
  and tool-call approval flows that would need a deliberate Sidemesh bridge.

## Current Architecture Findings

### What Works

- `AgentProviderCapabilities` gives the Flutter app a single feature-gating
  shape. This is the right direction for a mobile client that should not know
  provider-specific internals.
- Optional provider methods let non-Codex providers implement a smaller surface.
  Reference: `src/agent-provider.ts`.
- `MultiAgentProvider` correctly namespaces session IDs and routes session-bound
  calls back to the owning provider. Reference: `src/multi-provider.ts`.
- `MultiAgentProvider` wraps live events from child providers so the client can
  keep one WebSocket stream while still knowing which provider owns a session.
- The server already has a concrete-provider selection path for models, skills,
  and profiles. Reference: `/api/models`, `/api/skills`, and `/api/profiles` in
  `src/server.ts`.

### Original Problems And Current Status

The initial research identified these problems. The current branch has fixed
the capability and host-boundary issues, but the richer provider-runtime event
model is still pending.

- Fixed: `MultiAgentProvider` no longer OR-merges capabilities as public
  provider truth. Its `capabilities` field now mirrors the default provider.
  Reference: `src/multi-provider.ts`.
- Fixed: catalog routes no longer go through default-provider forwarding on the
  multi-provider facade. Skills, skill config, models, and profiles now select a
  concrete provider through runtime helpers. Reference: `src/server.ts`.
- Fixed: `/api/node` no longer exposes OR-merged `providerCapabilities`.
  `providerCapabilities` is now the default-provider compatibility alias, and
  `defaultProviderCapabilities` is explicit. Reference: `src/server.ts`.
- Fixed: server and mobile tests now exercise provider-scoped capability
  parsing/gating rather than OR-merged public truth. References:
  `src/provider-factory.test.ts`, `src/server.test.ts`,
  `apps/mobile/test/provider_metadata_models_test.dart`,
  `apps/mobile/test/api_client_provider_scoping_test.dart`, and
  `apps/mobile/test/capability_ui_gates_test.dart`.
- Fixed: `AgentProvider` no longer includes local filesystem methods in the
  shared surface. Provider-native filesystem helpers still exist on Codex and
  fake adapters as concrete methods, but they are not part of the common
  provider contract. Reference: `src/agent-provider.ts`.
- Still pending: the common `AgentProviderLiveEvent` union remains intentionally
  small and still drops or compresses provider-native events such as Codex goal,
  hook, warning, reasoning, and plan events; Copilot background/subagent/
  capability events; and Pi queue, auto-retry, and extension UI events.
  Reference: `src/agent-provider.ts`.

## Provider Fit Analysis

### Codex

Codex is the closest native fit for the current interface.

Local adapter behavior:

- `CodexAgentProvider` directly talks to `CodexBridge`.
- Session listing maps to `thread/list`.
- Session read maps to `thread/read`.
- Loaded session IDs map to `thread/loaded/list`.
- Create/resume/archive/rename/compact map to native `thread/*` RPCs.
- User input maps to `turn/start` or `turn/steer`.
- Interrupt maps to `turn/interrupt`.
- Skills map to `skills/list` and `skills/config/write`.
- Filesystem methods map to Codex app-server `fs/*` RPCs.
- Runtime events are translated in `emitCodexNotification()`.

Upstream fit:

- Codex app-server exposes first-class thread, turn, skill, filesystem,
  approval, and notification RPCs.
- The `rust-v0.128.0` refresh keeps those primitives and adds additional app
  server seams for thread goals (`thread/goal/*`), hooks (`hooks/list` plus
  hook lifecycle notifications), plugin list/read/install/uninstall, external
  agent config import, active permission-profile metadata, and account/rate
  limit notifications.
- Native thread status has richer flags such as waiting on approval and waiting
  on user input.
- Native notifications include plan updates, reasoning deltas, token usage,
  filesystem changes, skill changes, turn diffs, command output, terminal input,
  and file patch changes.
- Native server requests include structured user input, MCP elicitation, and
  permissions approval.

Mismatch:

- The local `AgentProviderLiveEvent` surface drops several native Codex events:
  goal updates, hook lifecycle, account/rate-limit changes, plugin changes,
  plan updates, reasoning text/summary deltas, richer thread status, and
  structured user-input requests.
- Codex upstream has user-input and elicitation-style primitives, but local
  `CODEX_PROVIDER_CAPABILITIES.interaction.userInput` and `elicitation` are
  currently false.
- Codex filesystem support is still provider-native upstream, but Sidemesh now
  treats local filesystem browsing as host-owned. Any future use of Codex
  `fs/*` should be treated as a provider-native remote-workspace exception, not
  as the daemon's local file API.

Implication:

Codex can remain the reference adapter, but its provider-native richness should
not force every provider to implement Codex-shaped workspace methods or every
Codex notification. Add new Sidemesh event and capability facets only when a
mobile UI or diagnostic consumer can render them.

### GitHub Copilot SDK

Copilot fits the session boundary, but Sidemesh has to build more state around
it than Codex.

Local adapter behavior:

- `CopilotAgentProvider` starts an SDK client and loads Sidemesh-owned state.
- Sidemesh creates and persists its own `ThreadRecord`, messages, activities,
  turns, runtime summary, archive state, and loaded-session state.
- SDK sessions are created/resumed lazily through `ensureSdkSession()`.
- Sidemesh maps active input to SDK `send()` with `mode: "enqueue"` or
  `mode: "immediate"`.
- Interrupt maps to SDK `abort()`.
- Permission, user-input, and elicitation requests are converted to Sidemesh
  pending actions.
- SDK events are normalized into Sidemesh assistant messages, activities,
  runtime updates, and turn completion.

Upstream fit:

- `CopilotClient.createSession()` and `resumeSession()` require permission
  handlers before session creation so events are not dropped.
- Session configuration includes model, reasoning effort, tools, commands,
  provider, model capabilities, hooks, working directory, streaming,
  sub-agent streaming, MCP servers, custom agents, config discovery, skill
  directories, disabled skills, infinite sessions, and GitHub token.
- Session configuration can also register a session filesystem provider, but
  that is session-scoped Copilot runtime storage. It should not be confused
  with Sidemesh's host-owned filesystem API.
- `CopilotSession` exposes `send`, `sendAndWait`, `abort`, `disconnect`,
  `setModel`, `getMessages`, typed event subscriptions, session RPC, and
  capability updates.
- The generated event union is much larger than the local Sidemesh event model:
  plan changes, background tasks, MCP server status, subagents, custom agents,
  extensions, skills loaded, reasoning deltas, and more.

Mismatch:

- Sidemesh persists a shadow session model rather than simply reflecting the SDK.
- Many upstream event types are ignored because the local event surface does not
  have equivalents.
- Copilot has richer interaction support than Codex locally, but only because
  the adapter maps SDK callbacks into Sidemesh pending actions.
- Copilot has dynamic session capability events such as
  `capabilities.changed`; Sidemesh currently treats provider capabilities as
  provider-level metadata rather than session-runtime state.

Implication:

Copilot supports the current provider abstraction at the UI/session boundary,
but the adapter is doing substantial translation and state ownership. The core
contract should avoid implying that all providers expose session history, event
replay, session filesystem, or dynamic session capabilities in the same way.

### Pi Coding Agent

Pi is the least natural fit.

Local adapter behavior:

- `PiAgentProvider` embeds Pi services and `AgentSession` in-process.
- Sidemesh tracks sessions, archived IDs, loaded sessions, active turns, and
  persisted snapshots.
- Create/resume loads a Pi `AgentSession` and subscribes to its native events.
- Input maps to `AgentSession.prompt()` or `AgentSession.steer()`.
- Interrupt maps to `AgentSession.abort()`.
- Model selection maps to Pi's model registry and `AgentSession.setModel()`.
- Reasoning effort maps to Pi's thinking level via `setThinkingLevel()`.
- Skills map to Pi's `resourceLoader.getSkills()`.

Upstream fit:

- Pi's core abstraction is `AgentSession`, not a remote provider API.
- `AgentSessionEvent` includes queue updates, manual/automatic compaction,
  thinking-level changes, session-info changes, and auto-retry events.
- Pi owns runtime behavior such as prompt-template expansion, skill-command
  expansion, compaction, model switching, thinking-level switching, extension
  hooks, custom tools, custom UI, and dynamic provider registration.
- `AgentSessionRuntime` owns session replacement, session shutdown,
  resume/new/fork flows, and extension lifecycle.
- Pi skills are local resources discovered from global, project, package,
  settings, and CLI locations.
- Pi extensions can register tools, commands, shortcuts, flags, providers,
  custom UI, and event handlers.
- Pi extension examples show both blocking tool-call gates and custom UI flows.
  Those are real interaction primitives, but they are embedded in Pi's runtime
  and TUI model rather than exposed as Sidemesh pending actions today.

Mismatch:

- Sidemesh treats Pi as one provider, while Pi itself can register multiple
  model providers internally.
- Sidemesh has no first-class event shape for Pi queue updates, auto-retry,
  extension UI, extension tools, or provider registration.
- Pi has no Sidemesh pending-action capability today, even though Pi extensions
  can implement user interaction and blocking tool-call policies internally.

Implication:

Pi should be treated as an embedded agent runtime adapter. It can implement the
common session facade, but Sidemesh should avoid forcing Pi into a Codex-shaped
provider model. A Sidemesh bridge for Pi interaction should start with typed
queue/thinking/retry/status events, then add `ctx.ui` pending-action support
only if the mobile client can render the requested UI.

## Desired Target Architecture

### Provider Contract

`AgentProvider` should describe provider-owned agent behavior only.

Keep in the shared contract:

- Provider identity: `kind`, `displayName`, `capabilities`.
- Provider lifecycle: `start`, `close`, `restart`, `health`, `getVersion`.
- Session history: `listSessionThreads`, `readSessionThread`,
  `readSessionLog`, `readSessionRuntime`, `listRecentUnindexedSessionThreads`.
- Session lifecycle: `createSession`, `submitInput`, `listLoadedSessionIds`,
  `resumeSessionThread`, `setSessionName`, `archiveSession`,
  `unarchiveSession`, `compactSession`, `interruptTurn`.
- Approvals and interaction: `respondToPendingAction`.
- Provider catalogs: `listModels`, `listProfiles`, `listSkills`,
  `writeSkillConfig`.
- Provider-specific remote workspace feature: `readRemoteGitDiff`, if Codex
  still needs it as a provider-owned exception.

Remove or isolate from the shared contract:

- `fsReadDirectory`
- `fsGetMetadata`
- `fsReadFile`
- `fsWriteFile`
- `fsCreateDirectory`
- `fsRemove`
- `fsCopy`
- `fsWatch`
- `fsUnwatch`

The local filesystem API should remain host-owned in `src/fs-routes.ts`.

Landed status:

- The shared `AgentProvider` interface now extends only core, session,
  approval, workspace, and configuration provider facets.
- `AgentFilesystemProvider` remains as an explicitly provider-native extension
  interface, but it is not part of the common `AgentProvider` surface.
- Codex and fake adapters still have concrete `fs*` methods. Treat those as
  legacy/provider-native implementation details until there is a specific
  remote-workspace feature that needs them.

### Runtime Registry

`AgentProviderRuntime` should become the explicit registry and selection layer.

Target responsibilities:

- Hold all concrete providers.
- Expose the default provider kind.
- Select a provider by kind.
- Return provider metadata and capability summaries.
- Start and close all providers.
- Provide a session facade only where session aggregation is useful.

Candidate runtime shape:

```ts
export interface AgentProviderRuntime {
  readonly defaultProviderKind: AgentProviderKind;
  readonly sessionProvider: AgentProvider;
  readonly providers: AgentProviderRuntimeEntry[];

  defaultProvider(): AgentProviderRuntimeEntry;
  getProvider(kind: string | null | undefined): AgentProviderRuntimeEntry | null;
  requireProvider(kind: string | null | undefined): AgentProviderRuntimeEntry;
  listProviders(): AgentProviderRuntimeEntry[];
}
```

This does not need to be the exact final API. The key design point is that the
server should select concrete providers through runtime helpers instead of
depending on a merged provider facade.

Landed status:

- The branch implements `defaultProviderKind`, `defaultProvider`,
  `providerForKind()`, and `providerForSessionId()` in
  `src/provider-factory.ts`.
- The branch keeps `provider` as the session facade for existing session routes.
- The exact candidate method names were simplified, but the selection-layer
  behavior is now in place.

### Multi-Provider Facade

`MultiAgentProvider` should stay focused on session-scoped behavior.

Keep:

- Start/close all providers.
- Namespace session IDs with `kind:base64url(rawId)`.
- Route `readSessionThread`, `readSessionLog`, `readSessionRuntime`,
  `resumeSessionThread`, `setSessionName`, `archiveSession`,
  `unarchiveSession`, `compactSession`, `submitInput`, `interruptTurn`, and
  `respondToPendingAction` by namespaced IDs.
- Aggregate `listSessionThreads`, `listRecentUnindexedSessionThreads`, and
  `listLoadedSessionIds`.
- Wrap live events with provider-scoped session/action IDs.
- Prefix stderr from non-default providers.

Remove or stop using for:

- Provider catalog routes.
- Provider configuration routes.
- Filesystem routes.
- Remote Git diff routes, unless explicitly scoped to a selected provider.
- Global capability truth.

Landed status:

- `MultiAgentProvider` keeps lifecycle/session/action/event behavior.
- Default-provider forwarding for catalog and remote Git routes has been
  removed from the facade and moved to concrete provider selection.
- Event wrapping still includes `fs_changed` watch IDs for compatibility, but
  local filesystem live updates are served by the host filesystem WebSocket.

### Capability Reporting

Expose capability data in layers:

- `hostCapabilities`: daemon-owned features such as local filesystem, local Git,
  terminal, port forwarding, and browser preview.
- `defaultProviderCapabilities`: capabilities for the configured default
  provider.
- `providers[]`: each configured provider with its own capability map.
- `providerCapabilities`: temporary compatibility alias. During migration, make
  this equal to `defaultProviderCapabilities`, not OR-merged capabilities.

Avoid presenting OR-merged provider capabilities as one callable provider.

Landed status:

- `/api/node` exposes `defaultProviderCapabilities`, `hostCapabilities`, and
  `supportedProviders[].capabilities`.
- The compatibility field `providerCapabilities` is now the default provider's
  capabilities.
- `/api/providers` mirrors provider summaries for provider-selection UI.

## Phased Implementation Plan

Phase status as of 2026-05-03:

- Phase 1 is complete in the current branch.
- Phase 2 is complete in the current branch, with helper names adjusted to the
  implemented `providerForKind()` / `providerForSessionId()` API.
- Phase 3 is complete for public capability truth and catalog routing; the only
  leftover is the compatibility `fs_changed` live-event wrapper.
- Phase 4 is complete for the shared contract and HTTP capability model; the
  concrete Codex/fake `fs*` helpers remain as provider-native implementation
  details.
- Phase 5 is complete for server routes and mobile capability parsing/gating.
- Phase 6 remains open, especially Codex `request_user_input` and MCP
  elicitation mapping plus any Pi `ctx.ui` bridge.
- Phase 7 remains open and is now the main next-phase expansion.
- Phase 8 is partially complete through `docs/provider-adapter-contract.md`;
  this document is being updated with the second research pass.

### Phase 1: Make `/api/node` Capabilities Honest

Goal:

Make the client stop treating OR-merged capabilities as the truth for the active
provider.

Server tasks:

- In `src/server.ts`, change `/api/node` response construction so
  `providerCapabilities` reflects the default provider's capabilities.
- Add `defaultProviderCapabilities` explicitly.
- Ensure `supportedProviders` or a new `providers` field includes capabilities
  for each configured provider, not just definitions.
- Keep `hostCapabilities` unchanged.
- Audit any server helper that reads `provider.capabilities` from the merged
  facade and decide whether it needs default-provider or concrete-provider
  semantics.

Mobile tasks:

- Inspect API models that parse `/api/node`.
- Confirm the app can read per-provider capability maps.
- Update UI gates that currently assume `providerCapabilities` is a global
  union.
- Prefer selected-session provider capabilities when rendering session-specific
  actions.
- Prefer selected catalog provider capabilities when rendering model/profile/
  skill settings.

Tests:

- Add server test coverage for `/api/node` in multi-provider mode.
- Assert `defaultProviderCapabilities` matches the default provider.
- Assert per-provider capability summaries preserve distinct provider flags.
- Assert `providerCapabilities` is not an OR-merged union after the migration.
- Update `src/multi-provider.test.ts` to stop asserting union capability
  behavior as the public truth.

Compatibility notes:

- Mobile clients that only understand `providerCapabilities` should keep working
  against the default provider.
- New mobile code should use provider-scoped capabilities when provider
  selection is visible.

### Phase 2: Add Runtime Selection Helpers

Goal:

Move concrete provider selection into `AgentProviderRuntime` instead of keeping
ad hoc lookup logic inside `src/server.ts`.

Server/runtime tasks:

- Extend `AgentProviderRuntime` in `src/provider-factory.ts` with default and
  lookup helpers.
- Use those helpers in `src/server.ts` for:
  - `/api/skills`
  - `/api/skills/config/write`
  - `/api/models`
  - `/api/profiles`
  - `/api/sessions/create`
  - provider restart/admin routes
- Preserve existing request behavior:
  - `agentProvider` selects provider for catalogs.
  - `provider` selects provider for session creation.
  - omitted provider falls back to the default provider.
- Keep `runtime.provider` or equivalent during migration so existing session
  routes can continue using the session facade.

Tests:

- Unit-test runtime lookup for:
  - default provider.
  - known provider kind.
  - unknown provider kind.
  - null/undefined provider request.
- Server-test unknown provider response behavior.
- Server-test default-provider fallback.

Compatibility notes:

- This phase should be mostly internal cleanup.
- Public behavior should not change except clearer errors if a route requests an
  unknown provider.

### Phase 3: Narrow `MultiAgentProvider`

Goal:

Make `MultiAgentProvider` a session aggregation and routing facade only.

Tasks:

- Stop treating `MultiAgentProvider.capabilities` as a public capability union.
- Either remove `mergeCapabilities()` or make it private to session aggregation
  behavior only.
- Remove server reliance on `MultiAgentProvider` for provider catalogs.
- Remove or deprecate default-provider forwarding methods:
  - `listSkills`
  - `writeSkillConfig`
  - `listProfiles`
  - `readRemoteGitDiff`
  - `fsReadDirectory`
  - `fsGetMetadata`
  - `fsReadFile`
  - `fsWriteFile`
  - `fsCreateDirectory`
  - `fsRemove`
  - `fsCopy`
  - `fsWatch`
  - `fsUnwatch`
- Keep `listModels` only if it remains explicitly provider-scoped through
  `options.provider`. Prefer moving that route directly to runtime provider
  selection too.

Tests:

- Keep tests for namespaced session IDs.
- Keep tests for event wrapping.
- Keep tests for action routing.
- Replace union-capability tests with explicit per-provider capability tests.
- Add a regression test where a non-default provider supports a feature but the
  default provider does not, and the default facade does not advertise that
  feature.

Compatibility notes:

- Existing session IDs are already namespaced in multi-provider mode, so session
  routes should remain stable.
- Catalog routes should already be provider-scoped before removing facade
  forwarding.

### Phase 4: Clean Up Host vs Provider Boundaries

Goal:

Make the code match the documented ownership model in `AGENTS.md`.

Tasks:

- Remove local filesystem methods from `AgentProvider` or move them behind a
  clearly named Codex-specific extension interface.
- Remove `workspace.filesystem` from provider capabilities, or mark it as a
  Codex app-server remote workspace capability rather than local filesystem.
- Keep local filesystem browse/read/write/watch in `src/fs-routes.ts`.
- Ensure `hostCapabilities` is the only source for local filesystem UI gates.
- Update `docs/provider-adapter-contract.md`:
  - Remove provider-owned `fs*` methods from the shared workspace section.
  - Clarify `readRemoteGitDiff` as provider-owned only if it requires provider
    context.
  - Clarify that local Git status/diff remains host-owned.
- Update `AGENTS.md` if the final contract wording changes.

Codex-specific decision:

- Option A: remove provider `fs*` completely and use only host FS routes.
- Option B: keep Codex app-server `fs*` behind a `CodexWorkspaceProvider`
  internal interface, not the shared `AgentProvider` contract.

Recommended choice:

- Use Option A for local file APIs unless Codex app-server FS has a concrete
  behavior that host FS cannot reproduce.
- Keep `fs_changed` as a host or provider event only if a route actually uses
  provider-side watch state.

Tests:

- Existing `fs-routes` tests should continue to own local filesystem behavior.
- Provider contract tests should no longer require filesystem methods.
- Server tests should verify local FS routes work without provider FS support.

Security notes:

- Filesystem routes are high-trust surface area per `AGENTS.md`.
- Do not expand remote/public exposure during this refactor.
- Keep workspace path validation in `src/workspace-scope.ts` as the guardrail
  for host filesystem routes.

### Phase 5: Make Catalogs Provider-Scoped End To End

Goal:

Make models, profiles, skills, and skill config reflect the selected provider,
not the default provider or merged facade.

Server tasks:

- Keep `/api/models` provider-scoped.
- Keep `/api/skills` provider-scoped.
- Keep `/api/profiles` provider-scoped.
- Keep `/api/skills/config/write` provider-scoped.
- Make route naming and request fields consistent:
  - `agentProvider` for catalog selection.
  - `provider` for session creation.
  - Consider standardizing later, but avoid a breaking API rename in this phase.

Provider tasks:

- Codex:
  - Keep profiles enabled.
  - Keep skill management enabled.
  - Keep model listing profile-aware.
- Copilot:
  - Keep profiles disabled.
  - Keep skill listing and skill management SDK-backed.
  - Keep mode/model/reasoning controls.
- Pi:
  - Keep profiles disabled.
  - Keep skill listing enabled.
  - Keep skill management disabled unless upstream has a stable enable/disable
    model Sidemesh can represent.
  - Keep model listing based on Pi's internal model registry.

Mobile tasks:

- Catalog UI should request catalogs for the selected provider.
- Session creation should send the selected provider.
- Runtime controls should be gated by the provider that owns the target session.
- Profile UI should not appear for Copilot/Pi unless their provider capabilities
  say profiles are supported.

Tests:

- Server tests for all catalog routes with explicit provider kind.
- Server tests for all catalog routes with omitted provider kind.
- Mobile tests for provider-scoped model/profile/skill parsing.
- Mobile tests for capability gates across Codex, Copilot, and Pi.

### Phase 6: Normalize Interaction And Approval Semantics

Goal:

Represent user-facing blocking interactions consistently without forcing every
provider to use Codex's approval shape.

Current state:

- Codex supports command, file-change, and permissions approvals locally.
- Copilot supports command/tool/file/permissions-style pending actions, plus
  user input and elicitation.
- Pi currently advertises no Sidemesh approvals or interaction, even though Pi
  extensions can do user interaction inside Pi.

Tasks:

- Review `src/approvals.ts` and `AgentPendingAction` in `src/agent-provider.ts`.
- Separate concepts:
  - approval to run or grant something.
  - user input requested by the agent.
  - elicitation/form request.
  - provider-native UI event that Sidemesh cannot yet render.
- Enable Codex `interaction.userInput` only after mapping
  `item/tool/requestUserInput` to Sidemesh pending actions.
- Enable Codex elicitation only if `mcpServer/elicitation/request` is mapped
  into the same UI model as Copilot.
- Leave Pi interaction false until there is a Sidemesh-hosted interaction bridge
  for Pi extensions, or explicitly document that Pi extension UI is handled
  inside Pi.

Tests:

- Approval normalization tests for provider-specific payloads.
- Pending-action routing tests through `MultiAgentProvider`.
- Server/client tests for user-input and elicitation capability gates.

### Phase 7: Add Optional Rich Runtime Events

Goal:

Expose richer provider-native behavior without making every provider emulate it.

Candidate event additions:

- `thread_status_changed`
- `plan_updated`
- `reasoning_delta`
- `reasoning_summary_delta`
- `queue_updated`
- `auto_retry_started`
- `auto_retry_finished`
- `provider_warning`
- `provider_native_event_available`

Provider mappings:

- Codex:
  - `turn/plan/updated` -> `plan_updated`
  - `item/reasoning/textDelta` -> `reasoning_delta`
  - `item/reasoning/summaryTextDelta` -> `reasoning_summary_delta`
  - `thread/status/changed` -> `thread_status_changed`
  - `warning` and `guardianWarning` -> `provider_warning`

- Copilot:
  - `plan_changed` -> `plan_updated`
  - assistant reasoning events -> reasoning events
  - MCP/server/custom-agent/background-task events -> provider-specific
    status events if the mobile UI has somewhere useful to show them
  - capabilities changes -> provider/session runtime update

- Pi:
  - `queue_update` -> `queue_updated`
  - `auto_retry_start` -> `auto_retry_started`
  - `auto_retry_end` -> `auto_retry_finished`
  - `thinking_level_changed` -> runtime update
  - compaction events already partially map to context-compaction activity

Rules:

- Do not leak raw upstream payloads directly to Flutter.
- Keep a typed Sidemesh event shape.
- Add events only when there is an expected UI or diagnostic consumer.
- Preserve the existing event stream for compatibility.

Tests:

- Provider-specific event translation tests.
- WebSocket event schema/serialization tests if available.
- Mobile parsing tests for any new event type used by the app.

### Phase 8: Documentation And Migration Cleanup

Goal:

Make the codebase guidance match the implementation.

Docs to update:

- `docs/provider-adapter-contract.md`
- `AGENTS.md`
- `CONTRIBUTING.md` if provider adapter contribution steps change.
- Mobile API docs or model comments if provider capability parsing changes.

Specific doc updates:

- Clarify that `AgentProviderRuntime` is the provider registry and selection
  layer.
- Clarify that `MultiAgentProvider` is a session facade, not a complete
  provider union.
- Clarify host-owned features:
  - local filesystem
  - local Git status and working diff
  - integrated terminal
  - port forwarding
  - browser preview
- Clarify provider-owned features:
  - session history
  - session lifecycle
  - input
  - approvals and interactive requests
  - provider model/profile/skill catalogs
  - provider-specific remote Git diff, if retained

## Expanded Remaining Work

The second research pass changes the priority order. The base runtime boundary
is in place, so the next useful work is to add typed provider-native richness in
small vertical slices.

### 1. Rich Event Envelope

Current Sidemesh reference:

- `src/agent-provider.ts` defines the current `AgentProviderLiveEvent` union.
- `src/multi-provider.ts` wraps session/action IDs and still wraps
  `fs_changed` watch IDs for compatibility.
- `src/server.ts` forwards provider `liveEvent` messages to the WebSocket
  stream.

Provider source evidence:

- Codex `rust-v0.128.0` emits `thread/status/changed`,
  `thread/goal/updated`, `thread/goal/cleared`, `turn/plan/updated`,
  `item/reasoning/textDelta`, `item/reasoning/summaryTextDelta`,
  `warning`, `guardianWarning`, `hook/started`, `hook/completed`,
  `account/rateLimits/updated`, and `externalAgentConfig/import/completed`.
- Copilot SDK `0.3.0` exposes `session.plan_changed`,
  `assistant.reasoning`, `assistant.reasoning_delta`,
  `permission.requested`, `elicitation.requested`,
  `capabilities.changed`, `session.background_tasks_changed`, and
  `session.skills_loaded`.
- Pi `v0.71.1` exposes `queue_update`, `thinking_level_changed`,
  `compaction_start`, `compaction_end`, `auto_retry_start`, and
  `auto_retry_end` at the `AgentSessionEvent` layer.

Implementation tasks:

- Add typed optional events rather than a raw `nativePayload` escape hatch.
- Start with diagnostic-safe events:
  `provider_warning`, `thread_status_changed`, `plan_updated`,
  `reasoning_delta`, `reasoning_summary_delta`, `queue_updated`,
  `auto_retry_started`, and `auto_retry_finished`.
- Add `thread_goal_updated` only after deciding whether Sidemesh wants a UI for
  Codex's persisted goal workflow.
- Keep raw upstream IDs and provider-specific payloads behind adapter-local
  translation.
- Update `MultiAgentProvider.wrapLiveEvent()` to namespace every event shape
  that includes `sessionId`, `action.sessionId`, or future provider-owned IDs.

Acceptance:

- Provider adapter tests prove translation for each added event.
- WebSocket serialization preserves backward compatibility for existing event
  types.
- Flutter adds parsing only for events it will render or store.

### 2. Codex Interaction Bridge

Current Sidemesh reference:

- `src/codex-provider.ts` still advertises
  `interaction.userInput: false` and `interaction.elicitation: false`.
- `src/approvals.ts` and `AgentPendingAction` already support a provider
  pending-action normalization layer.
- `src/copilot-provider.ts` already maps Copilot user input and elicitation into
  Sidemesh pending actions and is the best local template.

Provider source evidence:

- Codex `item/tool/requestUserInput` carries `threadId`, `turnId`, `itemId`,
  and multiple questions with optional choices.
- Codex `mcpServer/elicitation/request` carries `threadId`, optional `turnId`,
  `serverName`, and either form-mode schema or URL-mode request data.
- Codex has `thread/increment_elicitation` and `thread/decrement_elicitation`
  for out-of-band blocking state.

Implementation tasks:

- Map `item/tool/requestUserInput` to `AgentPendingAction.kind:
  "user_input"`.
- Map `mcpServer/elicitation/request` to `AgentPendingAction.kind:
  "elicitation"` using the same mobile-visible schema concepts as Copilot.
- Implement response serialization for accepted, declined, canceled, and
  free-form/other answers.
- Turn on Codex `interaction.userInput` and `interaction.elicitation` only after
  the request and response paths have tests.
- Emit `thread_status_changed` or runtime updates when Codex reports waiting on
  approval/user input.

Acceptance:

- Codex provider tests cover request parsing, action opening, action response,
  cancellation/decline, and namespaced multi-provider action routing.
- Mobile capability gates show user-input/elicitation UI only after the Codex
  capability flags are true.

### 3. Copilot Rich Event Cleanup

Current Sidemesh reference:

- `src/copilot-provider.ts` already translates messages, activities, pending
  actions, runtime summaries, and skill invalidation.
- The adapter owns a Sidemesh shadow session model, so events must update that
  model before being forwarded to the client.

Provider source evidence:

- SDK sessions register handlers before `session.create` / `session.resume` so
  early events are not dropped.
- `SessionConfig` includes streaming, subagent streaming, custom agents, MCP
  servers, skill directories, disabled skills, infinite sessions, hooks, and
  `createSessionFsHandler`.
- Generated events include plan, reasoning, background task, subagent,
  capabilities, skill-loaded, permission, and elicitation events.

Implementation tasks:

- Map `session.plan_changed` into `plan_updated` only when the resulting plan
  has enough content for mobile to render.
- Map `assistant.reasoning_delta` to `reasoning_delta` if streaming is enabled
  and if the UI will accumulate it.
- Map `capabilities.changed` into session runtime updates rather than mutating
  provider-level capabilities.
- Keep Copilot `sessionFs` out of the host filesystem contract. Consider it
  only for a future persistent remote workspace feature.
- Avoid surfacing subagent/background-task events as generic activities until
  there is a stable UX for them.

Acceptance:

- Copilot event fixtures cover all translated event types.
- The Sidemesh session snapshot stays consistent after replaying translated SDK
  events.
- No raw SDK event objects are emitted to Flutter.

### 4. Pi Runtime Bridge

Current Sidemesh reference:

- `src/pi-provider.ts` maps the shared session facade and reasoning effort to
  Pi thinking level.
- Pi interaction and approvals remain false in provider capabilities.

Provider source evidence:

- `AgentSessionEvent` already has queue, compaction, thinking-level, and
  auto-retry events.
- `Agent` owns steering and follow-up queues separately.
- Pi extensions can register providers, tools, commands, shortcuts, flags,
  custom UI, and tool-call gates. Example extensions include questionnaire and
  permission-gate flows.

Implementation tasks:

- Map `queue_update` to `queue_updated` with separate steering and follow-up
  counts/text previews.
- Map `auto_retry_start` and `auto_retry_end` to provider events or runtime
  updates.
- Map `thinking_level_changed` into `runtime_updated` if the runtime summary can
  represent it cleanly.
- Do not turn on Pi approvals or interaction until `ctx.ui.confirm`,
  `ctx.ui.select`, `ctx.ui.input`, and `ctx.ui.custom` have a deliberate
  Sidemesh pending-action bridge.
- Evaluate the `0.71.1` to `0.72.1` dependency bump separately before relying
  on any source behavior introduced after `v0.71.1`.

Acceptance:

- Pi adapter tests cover queue, retry, compaction, and thinking-level event
  mapping.
- Flutter ignores unknown Pi events safely.
- Pi extension UI remains internal until the Sidemesh bridge exists.

### 5. Legacy Surface Cleanup

Current Sidemesh reference:

- `providerCapabilities` remains for old clients.
- `AgentFilesystemProvider` exists as an explicit non-shared provider-native
  interface.
- Codex and fake adapters still expose concrete `fs*` helpers.
- `fs_changed` remains in `AgentProviderLiveEvent`.

Implementation tasks:

- Keep `providerCapabilities` until the mobile release matrix no longer needs
  the compatibility alias.
- Decide whether Codex/fake concrete `fs*` helpers are still useful. If not,
  delete them and their tests.
- If provider-side `fs_changed` has no consumer after host FS live updates,
  deprecate it or rename it to a provider-native workspace event.
- Avoid adding Codex plugin/hook/goal APIs to the core provider contract until
  another provider has a comparable concept or the UI has a Codex-specific
  provider page.

Acceptance:

- Removing any legacy method does not change host filesystem behavior.
- `docs/provider-adapter-contract.md`, `AGENTS.md`, and this plan stay aligned.
- Old clients still work until compatibility fields are deliberately removed.

## API Migration Detail

### `/api/node`

Original problem:

- `providerCapabilities` can be the OR-merged `MultiAgentProvider.capabilities`.

Current status:

- This is fixed in the current branch.
- `providerCapabilities` is a compatibility alias for
  `defaultProviderCapabilities`.
- Per-provider capability truth lives in `supportedProviders[].capabilities`.

Target response:

```json
{
  "provider": "codex",
  "providerName": "Codex",
  "providerVersion": "codex-cli 0.128.0",
  "providerCapabilities": {},
  "defaultProviderCapabilities": {},
  "hostCapabilities": {},
  "supportedProviders": [
    {
      "kind": "codex",
      "displayName": "Codex",
      "isDefault": true,
      "capabilities": {}
    },
    {
      "kind": "copilot",
      "displayName": "GitHub Copilot",
      "isDefault": false,
      "capabilities": {}
    }
  ]
}
```

Compatibility:

- `providerCapabilities` remains temporarily as an alias for
  `defaultProviderCapabilities`.
- New client code should prefer the matching entry in `supportedProviders`.

### Catalog Routes

Keep route behavior:

- `GET /api/models?agentProvider=codex`
- `GET /api/skills?agentProvider=codex&cwd=/repo`
- `GET /api/profiles?agentProvider=codex&cwd=/repo`
- `POST /api/skills/config/write` with `agentProvider`

Target rule:

- If `agentProvider` is omitted, use default provider.
- If `agentProvider` is unknown, return `400`.
- If provider lacks the capability or method, return `501`.
- Do not fall through to another provider just because another provider supports
  the capability.

### Session Routes

Keep route behavior:

- Session creation can choose provider.
- Session IDs are namespaced in multi-provider mode.
- Subsequent session operations route by namespaced session ID.

Target rule:

- Session operations should not need `agentProvider` after creation.
- The namespaced session ID should be the source of truth.
- Unknown provider namespace should return a clear error.

## Data Model Considerations

### Capabilities

The capability map is provider-local. The current branch no longer uses an
OR-merged provider map as public truth.

Target:

- Provider capabilities describe only what that provider can do.
- Host capabilities describe only what the daemon can do.
- Runtime-level capabilities should be avoided unless they describe an actual
  runtime-level callable behavior.

### Runtime Summary

Current `SessionRuntimeSummary` is shared across providers, but fields are not
uniformly sourced:

- Codex reads runtime metadata from Codex rollout logs and token usage events.
- Copilot builds runtime from SDK events and Sidemesh state.
- Pi builds runtime from `AgentSession` state and parsed history.

Target:

- Keep the common fields that the UI can render consistently.
- Use optional provider-specific telemetry only when typed and documented.
- Avoid assuming `eventReplay` means the same storage mechanism for every
  provider.

### Provider Events

Current events are common and simple.

Target:

- Preserve common events.
- Add optional richer events where they map to multiple providers or unlock a
  clear UI/diagnostic feature.
- Keep raw provider payloads out of the Flutter app.

## Risk Register

### Capability Behavior Changes

Risk:

- Older clients may have expected OR-merged `providerCapabilities`.

Mitigation:

- Keep `providerCapabilities` as default-provider capabilities for a transition
  period.
- Add explicit `supportedProviders[].capabilities` for new behavior.
- Coordinate Flutter changes before removing any legacy fields.

### Multi-Provider Session Routing

Risk:

- Changing `MultiAgentProvider` could break existing namespaced session IDs.

Mitigation:

- Keep namespacing stable.
- Keep session facade tests.
- Avoid changing public session route paths.

### Filesystem Ownership

Risk:

- Codex app-server FS may provide behavior different from host FS.

Mitigation:

- Compare Codex `fs*` behavior against `src/fs-routes.ts`.
- Keep host FS as the default local UI surface.
- Retain Codex-specific remote workspace support only if a concrete feature
  needs it.

### Pi Runtime Semantics

Risk:

- Forcing Pi into provider-shaped capability flags could hide important Pi
  runtime behavior.

Mitigation:

- Keep Pi adapter conservative.
- Add Pi-specific rich events only when the mobile app can represent them.
- Do not expose Pi extension UI through Sidemesh until there is an explicit
  interaction bridge.

### Event Surface Expansion

Risk:

- Adding many events could make the mobile app fragile.

Mitigation:

- Add events incrementally.
- Keep them typed.
- Only add UI consumers where the value is clear.

## Test Plan

### Server TypeScript Gates

Run after any TypeScript change:

```bash
npm run typecheck
npm run test:server
npm run build
```

Do not run tests if `npm run typecheck` fails.

### Focused Server Tests

Already covered by the current branch:

- `src/provider-factory.test.ts`
  - runtime helper selection
  - unknown provider handling
  - default provider fallback

- `src/multi-provider.test.ts`
  - namespaced session IDs
  - session routing
  - action routing
  - event wrapping
  - no public OR-merged capability truth

- `src/server.test.ts`
  - `/api/node` capability response shape
  - provider-scoped catalog routes
  - unknown provider route errors
  - unsupported capability route errors

Add next-phase provider-specific tests for:

- `src/codex-provider.test.ts`: Codex user-input, MCP elicitation, warning,
  thread-status, plan, and reasoning event mapping.
- `src/copilot-provider.test.ts`: Copilot plan, reasoning, capability,
  skill-loaded, and background/subagent event filtering/mapping.
- `src/pi-provider.test.ts`: Pi queue, thinking-level, auto-retry, and
  extension UI bridge behavior.
- `src/fake-provider.test.ts`: fake rich-event fixtures for mobile/WebSocket
  tests.

### Flutter Gates

Run after any Dart/Flutter change:

```bash
cd apps/mobile
flutter test test/provider_metadata_models_test.dart
flutter test test/api_client_provider_scoping_test.dart
flutter test test/capability_ui_gates_test.dart
flutter analyze
```

### Flutter Focus Areas

Already covered by the current branch:

- Parsing `defaultProviderCapabilities`.
- Parsing per-provider capabilities.
- Model/profile/skill UI gates by provider.
- Session action gates by session-owning provider.
- Default provider fallback behavior.
- Unknown provider error rendering if applicable.

Add next-phase tests only when the corresponding event/UI is implemented:

- Parsing `provider_warning`, `plan_updated`, and reasoning events.
- Rendering pending user input and elicitation for Codex.
- Ignoring unknown rich provider events safely.
- Showing Pi queue/retry/thinking status if the UI consumes those events.

## Recommended Implementation Order

Completed first-slice order:

1. Added tests that demonstrate the capability over-advertising problem.
2. Changed `/api/node` to expose default-provider and per-provider capabilities.
3. Updated Flutter API models and capability gates to consume provider-scoped
   capabilities.
4. Added runtime selection helpers in `src/provider-factory.ts`.
5. Moved server provider lookup to runtime helpers.
6. Narrowed `MultiAgentProvider` to session-scoped routing.
7. Removed local filesystem methods from the shared provider surface.
8. Updated provider contract docs.

Next-phase order:

1. Add typed rich event shapes and fake-provider fixtures.
2. Implement Codex warning/thread-status/plan/reasoning event mapping.
3. Implement Codex user-input and MCP elicitation pending actions.
4. Implement Copilot event cleanup for plan, reasoning, capability, skill, and
   background/subagent signals that have a UI consumer.
5. Implement Pi queue/retry/thinking events.
6. Decide whether Pi `ctx.ui` should bridge to Sidemesh pending actions.
7. Remove or deprecate legacy provider-native `fs*` helpers if no remote
   workspace feature uses them.
8. Revisit Codex goal/plugin/hook APIs only after deciding on a provider-page
   or provider-specific capability model.

## First Slice Recommendation

The first implementation slice was small and observable:

- Added failing tests around `/api/node` multi-provider capability reporting.
- Added `defaultProviderCapabilities`.
- Added provider capabilities to provider summaries.
- Made `providerCapabilities` reflect the default provider.
- Updated only the Flutter parsing/gating code needed for those fields.

This slice fixed the most misleading behavior without forcing a large adapter
rewrite. The next slice should be one provider/event path at a time, starting
with Codex user input or Codex warning/status events.

## Acceptance Criteria

First-slice criteria, satisfied by the current branch:

- `/api/node` no longer exposes OR-merged provider capabilities as the active
  provider's callable capability set.
- Provider catalogs are selected through concrete provider entries.
- `MultiAgentProvider` is used for session aggregation/routing, not global
  provider truth.
- Local filesystem UI depends on `hostCapabilities`, not provider capabilities.
- `docs/provider-adapter-contract.md` matches the implemented contract.
- Codex, Copilot, Pi, and fake provider tests pass.
- Focused Flutter provider metadata and capability-gate tests pass.

Expanded runtime criteria, still open:

- Codex user-input and MCP elicitation requests become Sidemesh pending actions.
- Codex, Copilot, and Pi rich events are represented by typed Sidemesh events.
- Raw provider payloads are not emitted to Flutter.
- Mobile parsing/rendering exists only for rich events with a real UI or
  diagnostic consumer.
- Legacy provider-native filesystem helpers are either removed or documented as
  provider-specific remote workspace exceptions.
