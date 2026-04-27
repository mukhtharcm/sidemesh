# Provider Adapter Contract

Sidemesh currently ships with a production Codex adapter and an in-process fake
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

Workspace:

- `readRemoteGitDiff`
- filesystem methods under `fs*`

Local git status and local working/staged/unstaged diffs are daemon-owned host
features. Providers only own `readRemoteGitDiff`, because that may require
agent/provider-specific context.

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

## HTTP Behavior

Server routes check both capability flags and method presence. A provider that
does not support a provider-owned route should produce a `501` instead of
forcing every adapter to implement Codex-only methods. Daemon-owned features
such as local git status are exposed through `hostCapabilities`.

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

The first real non-Codex provider should still start small: node metadata,
create session, submit text input, stream assistant text, and list recent
sessions if the agent has a durable session concept.
