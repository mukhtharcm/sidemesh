# Rich Event Envelope Implementation Plan

## Goal

Add a typed, provider-neutral event layer for runtime signals that are richer
than the current `activity_updated` and `runtime_updated` events.

This should not become an arbitrary provider event passthrough. The target is a
small set of Sidemesh-owned live events that can be emitted by Codex, Copilot,
Pi, and fake tests without leaking upstream protocol names into the client.

## Current State

- `src/agent-provider.ts` defines `AgentProviderLiveEvent`, but the union only
  covers file/skill invalidation, assistant deltas, activity updates, runtime
  telemetry, turn completion, and `action_opened`.
- `src/types.ts` mirrors the public WebSocket `LiveEvent` union. The mobile
  model currently parses only the existing top-level fields.
- `src/server.ts` has a switch over provider `liveEvent` values and only
  broadcasts known event types. New provider event types must be added there or
  they will be dropped.
- `src/multi-provider.ts` already rewrites event `sessionId` values into
  namespaced IDs and wraps `action_opened`. Any new event that carries
  `sessionId` must be covered by tests to avoid cross-provider routing bugs.
- `apps/mobile/lib/src/screens/session_screen.dart` handles live events around
  the existing `activity_updated`, `runtime_updated`, and `action_opened`
  branches. It does not yet render plans, reasoning, thread status, queue state,
  retry state, or provider warnings.

## Evidence Anchors

- `src/agent-provider.ts:184` defines `AgentProviderCapabilities`.
- `src/agent-provider.ts:239` defines the current `AgentProviderLiveEvent`
  union.
- `src/server.ts:466` is the provider live-event switch.
- `src/server.ts:567` forwards `runtime_updated`.
- `src/server.ts:615` forwards `action_opened`.
- `src/multi-provider.ts:82` subscribes to child provider live events.
- `apps/mobile/lib/src/models.dart:2515` defines mobile `LiveEvent`.
- `apps/mobile/lib/src/screens/session_screen.dart:2428` starts the mobile live
  event handler switch.
- Codex protocol `common.rs:1355` defines `thread/status/changed`.
- Codex protocol `common.rs:1371` defines `turn/plan/updated`.
- Codex protocol `common.rs:1397` and `common.rs:1399` define reasoning delta
  notifications.
- Codex protocol `common.rs:1404` and `common.rs:1405` define warning
  notifications.
- Copilot SDK `generated/session-events.ts:740` defines
  `session.plan_changed`.
- Copilot SDK `generated/session-events.ts:1736` defines
  `assistant.reasoning_delta`.
- Copilot SDK `generated/session-events.ts:2653` starts subagent lifecycle
  events.
- Copilot SDK `generated/session-events.ts:4358` defines
  `capabilities.changed`.
- Pi `agent-session.ts:117` defines `queue_update`.
- Pi `agent-session.ts:132` and `agent-session.ts:133` define auto-retry
  events.

## Upstream Provider Evidence

Codex exposes multiple notifications that Sidemesh currently ignores:

- `thread/status/changed` in Codex protocol common definitions.
- `turn/plan/updated` with a typed plan array in Codex `v2.rs`.
- `item/reasoning/summaryTextDelta` and `item/reasoning/textDelta`.
- `warning`, `guardianWarning`, `deprecationNotice`, and `configWarning`.
- `mcpServer/startupStatus/updated` and MCP OAuth/progress notifications.

Copilot SDK exposes equivalent or adjacent event types:

- `session.plan_changed`.
- `assistant.reasoning` and `assistant.reasoning_delta`.
- `subagent.started`, `subagent.completed`, `subagent.failed`,
  `subagent.selected`, and `subagent.deselected`.
- `capabilities.changed`.
- `session.background_tasks_changed`.
- `session.mcp_servers_loaded` and `session.mcp_server_status_changed`.

Pi exposes runtime events that are not represented today:

- `queue_update` with `steering` and `followUp` queues.
- `auto_retry_start` with attempt, max attempts, delay, and error message.
- `auto_retry_end` with success, attempt, and optional final error.
- `thinking_level_changed`, which is already partially mapped to
  `runtime_updated` in `src/pi-provider.ts`.

## Proposed Event Types

Add these public event shapes to `src/types.ts` and provider-side shapes to
`src/agent-provider.ts`.

`provider_warning`

```ts
{
  type: "provider_warning";
  sessionId?: string;
  level: "info" | "warning" | "error";
  code?: string;
  message: string;
  source?: string;
}
```

Use for Codex warning/deprecation/config warnings, Copilot warning/info
notifications, MCP status problems, and Pi retry failures. The server can stamp
`providerKind` later if needed, but the first version should avoid duplicating
provider identity in every event because multi-provider IDs already encode it.

`thread_status_changed`

```ts
{
  type: "thread_status_changed";
  sessionId: string;
  status: "idle" | "running" | "waiting_for_input" | "waiting_for_approval" | "errored" | "closed" | "unknown";
  message?: string;
  pendingActionKind?: PendingActionKind;
}
```

Use for Codex `thread/status/changed` and provider-owned waiting states. Keep
the status enum Sidemesh-owned, not Codex-owned.

`plan_updated`

```ts
{
  type: "plan_updated";
  sessionId: string;
  turnId?: string;
  explanation?: string;
  plan: Array<{
    step: string;
    status: "pending" | "in_progress" | "completed";
  }>;
}
```

Map Codex `turn/plan/updated` directly. Map Copilot `session.plan_changed` by
normalizing its plan entries into the same `step/status` shape.

`reasoning_delta`

```ts
{
  type: "reasoning_delta";
  sessionId: string;
  turnId?: string;
  itemId?: string;
  reasoningId?: string;
  delta: string;
  summary: boolean;
}
```

Use one event type for raw reasoning text and reasoning summary deltas. The
`summary` flag lets mobile render compact public summaries differently from
provider-internal reasoning. Do not persist or replay raw reasoning unless a
follow-up privacy policy explicitly allows it.

`queue_updated`

```ts
{
  type: "queue_updated";
  sessionId: string;
  steeringCount: number;
  followUpCount: number;
  steeringPreview?: string[];
  followUpPreview?: string[];
}
```

Map Pi `queue_update`. This can also represent future provider queue state.
Preview arrays should be truncated by the provider adapter, not by mobile.

`auto_retry_updated`

```ts
{
  type: "auto_retry_updated";
  sessionId: string;
  phase: "started" | "ended";
  attempt: number;
  maxAttempts?: number;
  delayMs?: number;
  errorMessage?: string;
  success?: boolean;
  finalError?: string;
}
```

Map Pi auto-retry events and future provider retry policies.

## Implementation Steps

1. Extend `AgentProviderLiveEvent` in `src/agent-provider.ts`.
2. Extend public `LiveEvent` in `src/types.ts`.
3. Add parsing helpers for status normalization and warning levels near the
   provider adapters, not in shared types.
4. Update the provider `liveEvent` switch in `src/server.ts` to broadcast the
   new events to session-scoped subscribers.
5. Update `src/multi-provider.ts` tests so every new `sessionId` event is
   namespaced when coming from non-default providers.
6. Update `apps/mobile/lib/src/models.dart` with nullable fields for the new
   live event payloads while preserving unknown-event tolerance.
7. Update `apps/mobile/lib/src/screens/session_screen.dart` to consume the new
   events with minimal first-pass UI.
8. Add fake-provider helpers to emit each new event shape for tests.

## Mobile UI Scope

First pass should be useful but conservative:

- Render `provider_warning` as a compact timeline/system row and, for `error`,
  optionally surface it in the header activity strip.
- Render `plan_updated` as a collapsible plan card in the timeline or header.
- Render `reasoning_delta` only if the session UI already has a safe place for
  streaming thinking content. Otherwise parse and ignore it until a dedicated UI
  follow-up.
- Render `queue_updated` as a small queued-message indicator near the composer.
- Render `auto_retry_updated` as activity state, not as a pending action.
- Render `thread_status_changed` through existing session running/waiting state
  if possible.

## Test Plan

Server tests:

- `src/server.test.ts` should verify every new event is broadcast to the
  correct session WebSocket and not to unrelated sessions.
- Multi-provider tests should verify IDs are namespaced for all new event
  shapes.
- Unknown event types should still be ignored or logged without crashing.

Provider tests:

- Fake provider should emit fixture events for all new event shapes.
- Codex provider tests should cover Codex notification mapping once Codex
  mapping is implemented.
- Copilot provider tests should cover Copilot event mapping once Copilot
  mapping is implemented.
- Pi provider tests should cover queue and retry mapping once Pi mapping is
  implemented.

Mobile tests:

- `models.dart` parsing tests for all new nullable fields.
- Session screen controller/widget tests for warning, plan, queue, and retry
  rendering.
- Backward compatibility test where a live event has an unknown type and extra
  payload keys.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Raw reasoning can contain sensitive or provider-internal content. The first
  version should avoid persistence and should render only if the product
  decision is explicit.
- A generic "provider event" blob would move complexity to Flutter and break
  the capability contract. Keep the public events typed.
- Event flooding can make mobile janky. Reasoning and queue events should be
  coalesced or throttled if providers emit them frequently.

## Acceptance Criteria

- The daemon can broadcast each new event shape from a fake provider.
- Multi-provider mode correctly namespaces every new session-scoped event.
- Mobile can parse every new event without crashing.
- At least warnings, plan updates, queue updates, and retry updates have visible
  mobile behavior.
- Codex, Copilot, and Pi implementation plans can reference these event types
  without inventing provider-specific live event payloads.
