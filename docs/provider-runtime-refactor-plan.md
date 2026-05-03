# Provider Runtime Refactor Plan

This document turns the current provider-runtime study into an implementation
plan. The main goal is to make provider capability reporting honest, keep
host-owned features out of the provider contract, and preserve the parts of the
multi-provider facade that already work well: session routing, event wrapping,
and provider startup.

## Current Conclusion

`AgentProviderRuntime` is not currently a runtime abstraction. It is a small
container that returns:

- `provider`: either a concrete provider or a `MultiAgentProvider`.
- `providers`: concrete provider entries with config and definition summaries.

Reference: `src/provider-factory.ts`

The real abstraction is spread across:

- `src/agent-provider.ts`: the shared provider contract and capability map.
- `src/multi-provider.ts`: the multi-provider facade and ID namespacing.
- `src/server.ts`: HTTP/WebSocket route selection and capability checks.
- Provider adapters: `src/codex-provider.ts`, `src/copilot-provider.ts`,
  `src/pi-provider.ts`, and `src/fake-provider.ts`.
- Flutter capability gates in `apps/mobile/`.

The current implementation is useful as a lowest-common-denominator UI/session
facade, but it does not accurately model what the upstream provider runtimes are.

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
`/tmp/sidemesh-provider-research`.

- Codex:
  - Installed CLI version observed during research: `codex-cli 0.124.0`.
  - Upstream tag used: `openai/codex` `rust-v0.124.0`.
  - Protocol definitions:
    `codex-rs/app-server-protocol/src/protocol/common.rs`
  - Detailed v2 types:
    `codex-rs/app-server-protocol/src/protocol/v2.rs`
  - Python SDK wrapper:
    `sdk/python/src/codex_app_server/api.py`

- GitHub Copilot SDK:
  - Dependency version: `@github/copilot-sdk@0.3.0`.
  - Upstream tag used: `github/copilot-sdk` `v0.3.0`.
  - Client/session creation:
    `nodejs/src/client.ts`
  - Session object and session RPC:
    `nodejs/src/session.ts`
  - Public SDK types:
    `nodejs/src/types.ts`
  - Generated session events:
    `nodejs/src/generated/session-events.ts`

- Pi coding agent:
  - Dependency version: `@mariozechner/pi-coding-agent@0.71.1`.
  - Upstream tag used: `badlogic/pi-mono` `v0.71.1`.
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

### What Does Not Work

- `MultiAgentProvider` OR-merges capabilities across providers and exposes that
  merged map through `provider.capabilities`. Reference:
  `mergeCapabilities()` in `src/multi-provider.ts`.
- Some facade methods still call only the default provider:
  `listSkills`, `writeSkillConfig`, `listProfiles`, `readRemoteGitDiff`, and
  every `fs*` method. Reference: `src/multi-provider.ts`.
- `/api/node` exposes `providerCapabilities: provider.capabilities`, which can
  be the OR-merged facade map in multi-provider mode. Reference: `src/server.ts`.
- The test suite currently asserts the OR-merged behavior instead of guarding
  against over-advertising. Reference: `src/multi-provider.test.ts`.
- The contract says optional methods must match advertised capabilities, while
  the multi-provider facade can advertise a capability that the default-provider
  facade method cannot actually serve. Reference: `AGENTS.md` and
  `docs/provider-adapter-contract.md`.
- Host-vs-provider ownership is inconsistent:
  `AGENTS.md` says local filesystem is host-owned, but `AgentProvider` still
  includes `fsReadDirectory`, `fsReadFile`, `fsWriteFile`, `fsWatch`, and related
  methods.

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
- Native thread status has richer flags such as waiting on approval and waiting
  on user input.
- Native notifications include plan updates, reasoning deltas, token usage,
  filesystem changes, skill changes, turn diffs, command output, terminal input,
  and file patch changes.
- Native server requests include structured user input and permissions approval.

Mismatch:

- The local `AgentProviderLiveEvent` surface drops several native Codex events:
  plan updates, reasoning text/summary deltas, richer thread status, and
  structured user-input requests.
- Codex upstream has user-input and elicitation-style primitives, but local
  `CODEX_PROVIDER_CAPABILITIES.interaction.userInput` and `elicitation` are
  currently false.
- Codex filesystem support is provider-native, but local filesystem browsing is
  documented as host-owned. This makes `fs*` in `AgentProvider` ambiguous.

Implication:

Codex can remain the reference adapter, but its provider-native richness should
not force every provider to implement Codex-shaped workspace methods.

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

Implication:

Copilot supports the current provider abstraction at the UI/session boundary,
but the adapter is doing substantial translation and state ownership. The core
contract should avoid implying that all providers expose session history and
event replay in the same way.

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
provider model.

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

## Phased Implementation Plan

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

## API Migration Detail

### `/api/node`

Current problem:

- `providerCapabilities` can be the OR-merged `MultiAgentProvider.capabilities`.

Target response:

```json
{
  "provider": "codex",
  "providerName": "Codex",
  "providerVersion": "codex-cli 0.124.0",
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

Current capability map is provider-local but is sometimes used globally.

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

- Older clients may expect OR-merged `providerCapabilities`.

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

Add or update tests for:

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

- Provider-specific tests:
  - `src/codex-provider.test.ts`
  - `src/copilot-provider.test.ts`
  - `src/pi-provider.test.ts`
  - `src/fake-provider.test.ts`

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

Add or update tests for:

- Parsing `defaultProviderCapabilities`.
- Parsing per-provider capabilities.
- Model/profile/skill UI gates by provider.
- Session action gates by session-owning provider.
- Default provider fallback behavior.
- Unknown provider error rendering if applicable.

## Recommended Implementation Order

1. Add tests that demonstrate the current capability over-advertising problem.
2. Change `/api/node` to expose default-provider and per-provider capabilities.
3. Update Flutter API models and capability gates to consume provider-scoped
   capabilities.
4. Add runtime selection helpers in `src/provider-factory.ts`.
5. Move server provider lookup to runtime helpers.
6. Narrow `MultiAgentProvider` to session-scoped routing.
7. Remove or isolate provider filesystem methods.
8. Update provider contract docs and `AGENTS.md`.
9. Add optional richer runtime events provider by provider.

## First Slice Recommendation

The first implementation slice should be small and observable:

- Add failing tests around `/api/node` multi-provider capability reporting.
- Add `defaultProviderCapabilities`.
- Add provider capabilities to provider summaries if missing.
- Make `providerCapabilities` reflect the default provider.
- Update only the Flutter parsing/gating code needed for those fields.

This slice fixes the most misleading behavior without forcing a large adapter
rewrite.

## Acceptance Criteria

The refactor is done when:

- `/api/node` no longer exposes OR-merged provider capabilities as the active
  provider's callable capability set.
- Provider catalogs are selected through concrete provider entries.
- `MultiAgentProvider` is used for session aggregation/routing, not global
  provider truth.
- Local filesystem UI depends on `hostCapabilities`, not provider capabilities.
- `docs/provider-adapter-contract.md` matches the implemented contract.
- Codex, Copilot, Pi, and fake provider tests pass.
- Focused Flutter provider metadata and capability-gate tests pass.
