# Provider Runtime V2

This document describes the next provider contract for Sidemesh.

The current `AgentProvider` contract works for sessions, turns, and runtime
controls, but it underspecifies the richer catalog and extension surfaces that
modern agent runtimes already expose. Pi, Copilot, and MCP-aligned runtimes all
have first-class concepts for prompts, tools, resources, and dynamic provider
registration that do not fit cleanly into Sidemesh's current
`models / skills / profiles` split.

This document turns the architecture discussion into an implementation plan.

## Goals

- Keep provider adapters honest about native capabilities.
- Move host-normalizable behavior out of provider-specific code where possible.
- Add first-class catalogs for MCP-aligned primitives.
- Let meta-runtimes such as Pi expose more of their own runtime model.
- Keep the first rollout incremental and backwards-compatible.

## Non-goals

- Replacing the current HTTP API in one PR.
- Forcing every provider to support every catalog immediately.
- Rewriting the mobile client before the daemon contract settles.

## What The Current Contract Gets Right

- Session lifecycle and replay are already first-class.
- Pending actions are normalized enough to carry approvals, user input, and
  elicitation.
- Live events already give the UI a provider-neutral stream for text and
  activity updates.

## What The Current Contract Misses

- Catalogs are too narrow.
  Today Sidemesh only has first-class surfaces for `models`, `skills`, and
  `profiles`, even though providers may expose prompts, tools, resources, or
  runtime-registered providers.

- Capabilities are too UI-shaped.
  Flags like `imageUrl`, `fileMentions`, and `searchSessions` mix hard backend
  limitations with behavior the host could normalize.

- Meta-runtimes are underspecified.
  Pi can dynamically discover prompts and other resources, register providers at
  runtime, and load extension-owned assets. Sidemesh currently hides most of
  that.

## Current Provider Findings

### Codex

Current adapter shape:

- RPC-backed app-server bridge with broad session and workspace coverage.
- Native support already exposed for:
  - session creation, resume, archive, compact, interrupt
  - replay and recent session fallback
  - remote filesystem and remote git diff
  - model listing
  - profile listing
  - skill listing and skill configuration writes
  - approval policy, sandbox, network access, web search, and fast-mode
    overrides

Implication:

- Codex is not the best first candidate for catalog expansion.
- It already fits the current contract better than the others.
- Future catalog work should only surface native Codex concepts that are
  discoverable through the RPC surface, not re-invent them in the host.

### Copilot

Current adapter shape:

- SDK-backed session lifecycle with replayable event history.
- Rich interactive runtime semantics already exist:
  - mode changes
  - permission requests
  - user input requests
  - elicitation requests
  - skill discovery and global skill configuration
  - compaction RPC
- The adapter already normalizes MCP-oriented approval requests into Sidemesh
  pending actions, which proves the contract is narrower than the runtime.

Implication:

- Copilot is a strong candidate for future tool/resource catalog work.
- The current contract hides some of the structure Copilot already has, even
  when execution remains SDK-owned.

### Pi

Current adapter shape:

- Sidemesh currently exposes only a narrow slice of Pi:
  - sessions
  - models
  - skills
  - local-image input
  - reasoning/model override
- Pi upstream itself has a much richer runtime:
  - `AgentSession`
  - `ResourceLoader`
  - extension runtime
  - `resources_discover`
  - dynamic provider registration
  - prompt templates as first-class resources

Implication:

- Pi is the most underexposed provider in Sidemesh today.
- It is the best first target for catalog expansion because prompts and dynamic
  resources already exist upstream.

### Fake

Current adapter shape:

- Deterministic harness used for provider-neutral tests and smoke coverage.

Implication:

- Every new provider-runtime primitive should land in the fake provider early so
  the server contract can stabilize before UI adoption.

## External Model

The long-term shape should align with MCP-style primitives:

- tools
- resources
- prompts
- client-side elicitation and approvals
- dynamic capability negotiation

Pi already exposes a close analogue through:

- `resources_discover`
- `ResourceLoader`
- runtime provider registration via `registerProvider()`
- extension-managed tools and prompts

Copilot also points in this direction with:

- richer session events
- detailed permission requests, including MCP-oriented approvals
- elicitation and user-input requests

## Provider Runtime V2 Shape

The contract should revolve around six primitives:

- sessions
- turns
- events
- pending actions
- runtime controls
- catalogs

Catalogs should grow beyond `models / skills / profiles` to include:

- models
- prompts
- tools
- resources
- skills
- profiles
- provider registrations

The host should aggregate these into a stable app surface.

## Host vs Provider Ownership

Provider-owned:

- session creation, resume, archive, rename, compact, interrupt
- runtime-native model and reasoning controls
- provider-native prompt/tool/resource catalogs
- provider-native pending actions
- provider-native remote workspace APIs

Host-owned:

- session search over normalized history
- image URL materialization where safe
- file mention materialization where safe
- app-facing catalog aggregation and presentation
- host-defined reusable presets where a provider has no native profiles

## Rollout Plan

### Phase 1: Introduce Catalog Primitives

- Add prompt catalog types to the core daemon contract.
- Add optional provider methods for prompt listing.
- Expose prompt listing through the HTTP API.
- Use the fake provider as the deterministic contract harness.
- Wire Pi into the new prompt catalog because it already exposes prompt
  templates upstream.

This PR implements Phase 1.

### Phase 2: Expand Catalog Coverage

- Add tool catalog primitives.
- Add resource catalog primitives and resource reads.
- Map Pi's dynamic resource discovery into those catalogs.
- Audit Copilot for prompt/resource/tool metadata worth surfacing.

Concrete follow-up tasks:

- Add `listTools()` to the provider contract.
- Add tool catalog entries with provider-owned metadata and stable ids.
- Add `listResources()` and `readResource()` for provider-owned resources.
- Extend Pi to expose dynamically discovered resources beyond prompt templates.
- Decide whether Copilot skills should remain a skill-only surface or also map
  into prompt/resource catalogs where that improves the app experience.

### Phase 3: Revisit Capability Semantics

- Replace boolean-only capability flags with more precise ownership states where
  needed.
- Move host-normalized features out of provider-specific booleans.
- Keep hard backend limits as provider capabilities.

### Phase 4: Dynamic Provider Surfaces

- Add a way for providers to surface runtime-registered providers or provider
  catalogs.
- Start with Pi, which already has dynamic provider registration.

Concrete follow-up tasks:

- Introduce a `ProviderRegistrationEntry` model.
- Add an optional `listRegisteredProviders()` contract method.
- Teach the Pi adapter to surface providers visible through its model registry,
  including extension-registered providers.
- Expose those through a daemon endpoint distinct from the static
  `/api/providers` registry metadata.

### Phase 5: Client Adoption

- Add prompt catalog views to the app.
- Fold prompts, skills, and future tool/resource catalogs into a unified
  provider-runtime browser.
- Keep the existing models/skills/profiles UI functional during migration.

## Provider Notes

### Codex

- Strongest current adapter.
- Already broad on runtime controls and remote workspace APIs.
- Least urgent for catalog expansion.
- Prompt/tool/resource support should be added only if the underlying RPC
  surface has native concepts worth exposing.

### Copilot

- Strong on events, approvals, mode switching, and interactive requests.
- Contract mismatch is larger than capability mismatch.
- Best future candidate for a richer tool/resource catalog surface.

### Pi

- Most underexposed runtime in the current daemon contract.
- Already supports prompts, dynamic resources, and runtime provider
  registration upstream.
- Best first provider for catalog expansion.
- Follow-up work after prompt catalogs:
  - host-materialized image URL support
  - dynamic resource catalogs
  - runtime-registered provider catalogs

### Fake

- Contract test harness.
- Should model the target surface early so server and provider-neutral tests can
  stabilize before UI adoption.

## Acceptance Criteria For Phase 1

- `AgentProvider` supports prompt catalogs.
- The daemon exposes `/api/prompts`.
- The fake provider implements deterministic prompt catalogs for tests.
- The Pi provider exposes prompt templates through the new catalog.
- Documentation reflects prompt catalogs as the first generalized runtime
  catalog slice.

## Implementation Notes For This PR

This first slice intentionally does not:

- add tool catalogs yet
- add provider/resource read endpoints yet
- change the mobile app
- redefine all capability semantics in one shot

Instead it establishes the pattern:

- new catalog type in core types
- optional provider method in `AgentProvider`
- capability gate in the daemon
- deterministic fake-provider implementation
- real Pi implementation
- server tests and smoke coverage
