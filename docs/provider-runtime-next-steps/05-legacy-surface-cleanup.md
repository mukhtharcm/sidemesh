# Legacy Surface Cleanup Implementation Plan

## Goal

Remove or quarantine older compatibility surfaces after the provider-runtime
contract is stable, without breaking existing mobile clients unnecessarily.

This is intentionally last in the sequence. Cleanup should happen only after
the rich event envelope, provider bridges, and search UX are validated.

## Current Legacy Surfaces

Provider filesystem methods:

- `src/agent-provider.ts` defines `AgentFilesystemProvider`.
- `src/codex-provider.ts` still has concrete `fs/watch` and `fs/unwatch`
  bridge methods.
- `src/fake-provider.ts` still has fake provider filesystem watch methods.
- Provider-level `fs_changed` exists in `AgentProviderLiveEvent`.

Host filesystem API:

- `src/fs-routes.ts` owns the WebSocket filesystem watch implementation.
- `apps/mobile/lib/src/workspace_live_store.dart` consumes host filesystem
  watch messages and expects `fs_changed`.
- This host-owned path is the preferred direction.

Compatibility `/api/node` fields:

- `src/server.ts` returns `providerCapabilities`,
  `defaultProviderCapabilities`, `hostCapabilities`, and `supportedProviders`.
- `apps/mobile/lib/src/models.dart` parses both `providerCapabilities` and
  `defaultProviderCapabilities`, with fallback behavior for older servers.
- `supportedProviders[].capabilities` is the per-provider truth in
  multi-provider mode.

Provider capability fallbacks:

- Older clients may still read `providerCapabilities`.
- Current mobile supports `defaultProviderCapabilities` and
  `supportedProviders`, but compatibility cannot be removed until the minimum
  supported client version is known.

## Evidence Anchors

- `src/agent-provider.ts:361` defines `AgentFilesystemProvider`.
- `src/agent-provider.ts:241` includes provider-originated `fs_changed`.
- `src/codex-provider.ts:391` calls Codex `fs/watch`.
- `src/codex-provider.ts:401` calls Codex `fs/unwatch`.
- `src/codex-provider.ts:481` emits provider-originated `fs_changed`.
- `src/fake-provider.ts:709` implements fake provider watch.
- `src/fake-provider.ts:1273` emits fake provider `fs_changed`.
- `src/fs-routes.ts:375` owns host filesystem watch subscription.
- `src/fs-routes.ts:429` emits host WebSocket `fs_changed`.
- `apps/mobile/lib/src/workspace_live_store.dart:146` handles host
  `fs_changed`.
- `src/server.ts:692` builds `/api/node` provider capability fields.
- `src/server.ts:711` includes compatibility `providerCapabilities`.
- `src/server.ts:712` includes `defaultProviderCapabilities`.
- `src/server.ts:713` includes `hostCapabilities`.
- `src/server.ts:716` includes `supportedProviders`.
- `apps/mobile/lib/src/models.dart:124` parses `providerCapabilities`.
- `apps/mobile/lib/src/models.dart:127` parses `defaultProviderCapabilities`.

## Cleanup Principles

- Host-owned filesystem stays. Provider-owned filesystem goes unless a provider
  requires it for a non-host workspace.
- `/api/node.providerCapabilities` stays until an explicit mobile compatibility
  cutoff is declared.
- Provider-specific protocol shapes should not enter `src/types.ts` unless the
  Sidemesh abstraction cannot model the concept.
- Unknown event and capability fields must remain safe for forward
  compatibility.

## Phase 1: Document Current Compatibility Contract

Update docs before deleting anything:

- `docs/provider-adapter-contract.md`
- `CONTRIBUTING.md`
- `AGENTS.md` if the gotcha would help future agents

Document:

- `hostCapabilities` means host-owned features.
- `defaultProviderCapabilities` means the selected default provider.
- `supportedProviders[].capabilities` is required for per-provider truth.
- `providerCapabilities` is a compatibility alias for
  `defaultProviderCapabilities`.
- Provider adapters should not implement filesystem operations unless a future
  non-host workspace provider requires it.

Acceptance:

- A new provider author can tell which features belong to host vs provider.
- The docs name the legacy fields that must not be removed yet.

## Phase 2: Add Deprecation Tests

Before removing code, add tests that pin the compatibility behavior:

- `/api/node` still includes `providerCapabilities`.
- `/api/node.defaultProviderCapabilities` equals the default provider
  capabilities.
- `/api/node.supportedProviders` includes per-provider capabilities.
- Multi-provider default capability behavior is unchanged.
- Mobile model parsing handles servers with and without
  `defaultProviderCapabilities`.

These tests make later cleanup intentional instead of accidental.

## Phase 3: Quarantine Provider Filesystem

Audit all references to:

- `AgentFilesystemProvider`
- `fsRead`
- `fsWrite`
- `fsMkdir`
- `fsDelete`
- `fsWatch`
- `fsUnwatch`
- provider-originated `fs_changed`

Expected direction:

- Keep `src/fs-routes.ts` and `workspace_live_store.dart` unchanged as the
  active host-owned filesystem path.
- Remove provider filesystem methods from `src/codex-provider.ts` if no caller
  uses them.
- Remove fake provider filesystem methods or move them into tests only if no
  server path needs them.
- Remove provider `fs_changed` from `AgentProviderLiveEvent` only after all
  providers and tests stop emitting it.

If any provider filesystem method is still needed:

- Rename the interface to make it explicitly experimental, for example
  `AgentRemoteWorkspaceProvider`.
- Keep it out of the base provider contract.
- Document why host routes cannot satisfy that case.

Acceptance:

- `rg "AgentFilesystemProvider"` has either zero production references or one
  clearly documented experimental reference.
- Provider `fs_changed` is not confused with host filesystem WebSocket
  `fs_changed`.
- Mobile workspace live reload continues to work through `src/fs-routes.ts`.

## Phase 4: Narrow Compatibility Fields

Do not remove `/api/node.providerCapabilities` immediately.

Instead:

1. Add a server comment naming it as a compatibility alias.
2. Add a mobile TODO near the fallback parser explaining the future removal.
3. Add release notes or docs saying clients should use
   `defaultProviderCapabilities` and `supportedProviders`.
4. After one release cycle, remove mobile dependency on the alias.
5. After the minimum client version cutoff, remove the server alias.

Acceptance:

- Current mobile still works with current daemon.
- Current mobile still works with one release older daemon where possible.
- New clients use the explicit fields.

## Phase 5: Remove Dead Provider Methods

Only after phases 1 through 4:

- Delete unused provider filesystem methods.
- Delete dead fake provider helpers that only existed for the old provider fs
  path.
- Delete provider-originated `fs_changed` event if unused.
- Run full server and mobile gates.

Expected files:

- `src/agent-provider.ts`
- `src/codex-provider.ts`
- `src/fake-provider.ts`
- `src/server.test.ts`
- `src/*provider*.test.ts`
- `docs/provider-adapter-contract.md`
- `CONTRIBUTING.md`

## Test Plan

Server tests:

- `/api/node` compatibility shape.
- Host filesystem WebSocket watch still emits `fs_changed`.
- Provider filesystem APIs are not required for workspace browsing.
- Multi-provider capabilities still report the default provider and all
  supported providers correctly.

Mobile tests:

- `NodeInfo.fromJson` parses current and legacy `/api/node` payloads.
- Capability-gated UI uses the selected provider capabilities.
- Workspace live store still handles host `fs_changed`.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `npm run build`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Removing `providerCapabilities` too early can break installed mobile clients.
- Removing provider filesystem methods without checking hidden callers can break
  tests or future remote-workspace experiments.
- Renaming `fs_changed` on the host WebSocket path would break mobile workspace
  live updates. The host event name can stay even if provider-originated
  `fs_changed` goes away.

## Acceptance Criteria

- Compatibility surfaces are documented before removal.
- Provider filesystem is either removed or explicitly quarantined.
- `/api/node` migration path is clear.
- No mobile client behavior changes accidentally.
