# Copilot Rich Event Cleanup Implementation Plan

## Goal

Use Copilot SDK's richer event stream without changing provider ownership.
Copilot already owns user input, elicitation, permissions, models, profiles,
skills, and runtime updates. This plan fills the remaining gaps by normalizing
Copilot plan, reasoning, background, subagent, MCP, and warning events into the
provider-neutral event envelope from `01-rich-event-envelope.md`.

## Current State

- `src/copilot-provider.ts` already advertises
  `interaction.userInput = true` and `interaction.elicitation = true`.
- `src/copilot-provider.ts` already maps Copilot user-input and elicitation
  requests into Sidemesh `action_opened` pending actions.
- `src/copilot-provider.ts` already maps many Copilot SDK timeline events into
  activity and runtime updates.
- The adapter does not yet expose Copilot plan changes, reasoning deltas,
  background task state, subagent lifecycle, or MCP server status as typed
  Sidemesh events.
- Mobile has generic pending-action UI already. This work should not redesign
  that path.

## Evidence Anchors

- `src/copilot-provider.ts:148` defines Copilot capabilities.
- `src/copilot-provider.ts:1316` handles Copilot user-input requests.
- `src/copilot-provider.ts:1335` handles Copilot elicitation requests.
- `src/copilot-provider.ts:1969` builds public Copilot user-input actions.
- `src/copilot-provider.ts:2002` builds public Copilot elicitation actions.
- Copilot SDK `generated/session-events.ts:740` defines
  `session.plan_changed`.
- Copilot SDK `generated/session-events.ts:1702` defines
  `assistant.reasoning`.
- Copilot SDK `generated/session-events.ts:1736` defines
  `assistant.reasoning_delta`.
- Copilot SDK `generated/session-events.ts:2653` starts subagent lifecycle
  events.
- Copilot SDK `generated/session-events.ts:3982` defines
  `mcp.oauth_required`.
- Copilot SDK `generated/session-events.ts:4358` defines
  `capabilities.changed`.
- Copilot SDK `generated/session-events.ts:4510` defines
  `session.background_tasks_changed`.
- Copilot SDK `generated/session-events.ts:4654` and
  `generated/session-events.ts:4696` define MCP server load/status events.

## Copilot SDK Evidence

The Copilot SDK clone exposes these event types:

- `session.plan_changed`
- `assistant.reasoning`
- `assistant.reasoning_delta`
- `subagent.started`
- `subagent.completed`
- `subagent.failed`
- `subagent.selected`
- `subagent.deselected`
- `mcp.oauth_required`
- `mcp.oauth_completed`
- `capabilities.changed`
- `session.background_tasks_changed`
- `session.skills_loaded`
- `session.custom_agents_updated`
- `session.mcp_servers_loaded`
- `session.mcp_server_status_changed`

The SDK `SessionConfig` also includes provider-owned settings for MCP servers,
custom agents, hooks, infinite/background sessions, session filesystem, and
streaming options. Those should remain inside `src/copilot-provider.ts`; the
public Sidemesh interface should expose only normalized capabilities and events.

## Event Mapping Plan

Map Copilot SDK events to the shared events from
`01-rich-event-envelope.md`.

`session.plan_changed`

- Emit `plan_updated`.
- Normalize Copilot plan item status into `pending`, `in_progress`, or
  `completed`.
- Include a short `explanation` only if the SDK payload has an equivalent
  summary.
- Do not inject plan updates into assistant messages.

`assistant.reasoning` and `assistant.reasoning_delta`

- Emit `reasoning_delta`.
- Set `summary = false` unless the SDK explicitly identifies a summary.
- Use Copilot `reasoningId` as `reasoningId`.
- Avoid persistence in first version.
- Throttle if the SDK emits very small chunks.

`capabilities.changed`

- Do not mutate the static `/api/node` provider-definition capability contract
  on every event.
- Treat it as runtime/session state. Emit `runtime_updated` if it changes
  model/runtime controls for the active session.
- Emit `provider_warning` only if the capabilities event indicates loss of a
  feature already in use.

`session.background_tasks_changed`

- First pass: emit `provider_warning` with `level = "info"` or an
  `activity_updated` row if it affects the visible session.
- Follow-up: add a dedicated `background_tasks_updated` event only if the UI
  needs structured background task counts.

`subagent.*`

- First pass: map started/completed/failed to `activity_updated` rows with
  stable activity IDs.
- If subagent selection state becomes important to the UI, add a typed
  `subagent_updated` event in a later iteration instead of overloading
  `provider_warning`.

`mcp.oauth_required` and `mcp.oauth_completed`

- If the SDK already turns OAuth into an elicitation or URL action, keep using
  pending actions.
- If these are pure status events, emit `provider_warning`.
- Do not add host-owned OAuth behavior to Sidemesh until the provider contract
  explicitly models OAuth flows.

`session.mcp_servers_loaded` and `session.mcp_server_status_changed`

- Emit `provider_warning` for error states.
- Consider a future `provider_status_updated` event for structured MCP status,
  but avoid adding it in the first pass unless mobile has a concrete rendering.

`session.skills_loaded` and `session.custom_agents_updated`

- Use existing `skills_changed` only when the Sidemesh skill list cache should
  be invalidated.
- Do not overload `skills_changed` for custom agents if the client cannot fetch
  custom-agent metadata.

## Adapter Implementation Steps

1. Identify the central Copilot SDK event dispatch path in
   `src/copilot-provider.ts`.
2. Add a local normalizer per event family:
   `emitCopilotPlanEvent`, `emitCopilotReasoningEvent`,
   `emitCopilotSubagentEvent`, `emitCopilotMcpStatusEvent`, and
   `emitCopilotBackgroundEvent`.
3. Keep each normalizer narrow and typed with defensive `unknown` parsing.
4. Add fixtures from Copilot SDK event shapes in the provider test file.
5. Emit only shared Sidemesh event types defined in
   `01-rich-event-envelope.md`.
6. Leave existing pending-action, runtime, model, and profile behavior
   unchanged unless a test proves it conflicts with the new events.

## Mobile Implementation Steps

Mobile work should mostly come from the rich event envelope plan:

- Parse `plan_updated`, `reasoning_delta`, and `provider_warning` in
  `apps/mobile/lib/src/models.dart`.
- Render plan changes using the shared plan UI.
- Render Copilot reasoning only if reasoning display is enabled for all
  providers.
- Render subagent activity through existing activity rows if the adapter emits
  `activity_updated`.
- Render MCP status as warnings or compact info rows.

## Test Plan

Copilot provider tests:

- `session.plan_changed` emits `plan_updated`.
- Reasoning delta emits `reasoning_delta` with the correct session ID and
  reasoning ID.
- Subagent started/completed/failed emits stable activity rows.
- MCP status error emits `provider_warning`.
- Skills loaded invalidates skills only when appropriate.
- Existing user-input and elicitation tests continue to pass.

Server tests:

- The new Copilot event shapes are broadcast like all other typed events.
- Multi-provider namespacing works for Copilot events.

Mobile tests:

- Copilot-shaped plan event parses and renders in the same UI as Codex plan.
- Unknown Copilot-specific fields are ignored.
- Provider warnings from Copilot render without blocking the session.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Copilot SDK has many event types. Mapping all of them at once can create UI
  noise. Start with plan, reasoning, warnings, and visible activity.
- `capabilities.changed` sounds like it should update `/api/node`, but that API
  is node/provider metadata. Session-specific runtime changes belong in
  `runtime_updated`.
- MCP OAuth needs a careful product decision. Do not add a Sidemesh OAuth
  system as an accidental side effect of event cleanup.

## Acceptance Criteria

- Copilot plan updates render through the same UI as Codex plan updates.
- Copilot reasoning deltas parse and either render or are safely ignored based
  on the shared reasoning policy.
- Copilot background/subagent/MCP status no longer disappears silently when it
  affects the visible session.
- Existing Copilot pending actions and model/runtime controls are unchanged.
