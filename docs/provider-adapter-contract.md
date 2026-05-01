# Provider Adapter Contract

Sidemesh currently ships with a production Codex adapter, a text-first GitHub
Copilot CLI adapter, and an in-process fake test adapter. The daemon is
structured so future agents can be added behind the same host/session API.

## Entry Points

- Register provider metadata and config loading in `src/provider-registry.ts`.
- Construct the provider through `src/provider-factory.ts`.
- Implement the provider contract in `src/agent-provider.ts`.
- Keep provider-specific protocol translation inside the adapter file, like
  `src/codex-provider.ts`.
- Use `src/fake-provider.ts` as the deterministic contract harness when adding
  or testing provider-neutral app behavior.

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
- filesystem methods under `fs*`

Local git status, local working/staged/unstaged diffs, integrated terminals, and
port forwarding are daemon-owned host features. Providers only own
`readRemoteGitDiff`, because that may require agent/provider-specific context.

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
- `fs_changed`
- `skills_changed`

Provider adapters should translate native agent events into Sidemesh activity
types instead of leaking provider-specific wire payloads to the Flutter app.

## Provider-Neutral Interactions

Agent questions, forms, OAuth/browser handoffs, todos, and planning state are
provider-neutral UX concepts. Adapters must not rely on provider-specific raw
tool JSON for these states.

The daemon represents interactive requests as `PendingAction` records:

- `kind: "user_input"` for a question with optional choices.
- `kind: "elicitation"` for structured input or URL handoff.
- `state: "pending"` for a live provider callback.
- `state: "recovered"` for a request restored after daemon restart.
- `recoverable: true` when Sidemesh can safely send the answer as a follow-up if
  the original provider callback is gone. Plain `user_input` questions default
  to recoverable.
- `recoverable: false` when an adapter knows the request must not be replayed
  after restart. Structured `elicitation` requests default to non-recoverable;
  adapters must opt in only when the request and submitted values are safe to
  serialize into a chat follow-up.
- `relatedActivityId` when the pending action corresponds to a timeline tool
  activity that should be marked completed when a recovered response is sent.

The daemon persists recoverable interaction requests in its state directory.
When the provider process is still alive, `respondToPendingAction()` resolves
the native callback. After a daemon restart, there is no provider promise left
to resolve, so Sidemesh sends the response back into the same session as a
normal follow-up message. This is intentionally explicit in the UI so the user
can see that the daemon recovered from a restart rather than pretending the
original tool call still exists.

Tool activities should still be recorded, but interaction tools must be
semantic:

- `category: "interaction", action: "ask"` for question tools like
  Copilot `ask_user` or other provider question/select dialogs.
- `category: "interaction", action: "report"` for intent/status tools like
  Copilot `report_intent`.

The Flutter UI renders these as "Model asked ..." and "Model reported intent
..." cards instead of raw tool-call JSON.

## Reference Architecture

Provider integrations should separate model/provider transport, the agent loop,
tools/extensions, persisted session entries, and UI/RPC. Sidemesh should copy
that separation, not provider-specific UI behavior.

Relevant patterns:

- Model providers produce normalized message/content blocks before they reach
  the app UI.
- Tool calls and tool results are durable transcript entries.
- Questions return tool results; answers are not fake user messages while the
  live tool call still exists.
- Todo and plan state can be reconstructed from tool-result details or custom
  session entries.
- RPC UI requests are explicit interaction events (`select`, `confirm`,
  `input`, `editor`) that a remote UI can render without knowing the terminal
  implementation.

Sidemesh should use this as the provider-contract target for future providers.
Direct API providers can follow the same model/provider split. CLI or
SDK-backed providers should translate their native events into the same
Sidemesh events instead of introducing provider-specific timeline renderers.

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
  `providerCapabilities`, `hostCapabilities`, and supported provider metadata.
- `/api/providers` exposes daemon-supported provider definitions for future
  provider-selection UI.
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
explicit host defaults layered on top when configured. Images, skills,
filesystem, and richer native tool translation should be enabled only when the
adapter can report honest capabilities and translate SDK events into Sidemesh
event types. The Copilot adapter uses `auto` as the Sidemesh default for
app-started turns, so a costly persistent Copilot setting is not consumed by
accident.
