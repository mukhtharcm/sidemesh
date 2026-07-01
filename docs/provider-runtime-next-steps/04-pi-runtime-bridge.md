# Pi Runtime Bridge Implementation Plan

## Goal

Expose Pi-specific runtime state through provider-neutral Sidemesh events and
complete the decision around Pi extension UI (`ctx.ui`) support.

The first implementation should focus on safe runtime observability:

- Queue state.
- Auto-retry state.
- Thinking-level/runtime updates.
- Compaction visibility.
- Extension UI bridge feasibility.

Provider-owned UI prompts should become pending actions only when the adapter
can faithfully round-trip the provider request and the mobile UI can represent
the prompt safely.

## Current State

- `src/pi-provider.ts` implements the Pi provider.
- `PI_PROVIDER_CAPABILITIES.interaction.userInput` and
  `PI_PROVIDER_CAPABILITIES.interaction.elicitation` are currently `false`.
- `PI_PROVIDER_CAPABILITIES.searchSessions` is currently `false`.
- `handleSessionEvent` already processes `session_info_changed`,
  `thinking_level_changed`, `compaction_start`, `compaction_end`,
  `message_update`, `message_end`, `tool_execution_start`,
  `tool_execution_update`, and `agent_end`.
- `thinking_level_changed` is already mapped into `runtime_updated`.
- Pi `queue_update`, `auto_retry_start`, and `auto_retry_end` are currently not
  represented in the shared event model.
- Pi custom messages are converted to text by helpers such as
  `customPiMessageText`, but extension custom UI is not bridged.

## Evidence Anchors

- `src/pi-provider.ts:131` defines Pi capabilities.
- `src/pi-provider.ts:807` handles Pi session events.
- `src/pi-provider.ts:817` currently handles `thinking_level_changed`.
- `src/pi-provider.ts:973` handles custom message text conversion.
- Pi `agent-session.ts:117` defines `queue_update`.
- Pi `agent-session.ts:123` defines `thinking_level_changed`.
- Pi `agent-session.ts:132` defines `auto_retry_start`.
- Pi `agent-session.ts:133` defines `auto_retry_end`.
- Pi `agent-session.ts:439` emits queue updates.
- Pi `agent-session.ts:1519` emits thinking-level updates.
- Pi `agent-session.ts:2468` and `agent-session.ts:2481` emit auto-retry
  events.
- Pi extension docs `extensions.md:856` starts the `ctx.ui` section.
- Pi extension docs `extensions.md:2118` through `extensions.md:2130` show
  select, confirm, input, editor, and notify examples.
- Pi extension docs `extensions.md:2329` describes `ctx.ui.custom`.
- Pi example `permission-gate.ts:25` uses `ctx.ui.select` for a dangerous
  command.
- Pi example `questionnaire.ts:102` uses `ctx.ui.custom`.

## Pi Source Evidence

The Pi monorepo defines `AgentSessionEvent` with:

```ts
| {
    type: "queue_update";
    steering: readonly string[];
    followUp: readonly string[];
  }
| { type: "compaction_start"; reason: "manual" | "threshold" | "overflow" }
| { type: "session_info_changed"; name: string | undefined }
| { type: "thinking_level_changed"; level: ThinkingLevel }
| {
    type: "compaction_end";
    reason: "manual" | "threshold" | "overflow";
    result: CompactionResult | undefined;
    aborted: boolean;
    willRetry: boolean;
    errorMessage?: string;
  }
| {
    type: "auto_retry_start";
    attempt: number;
    maxAttempts: number;
    delayMs: number;
    errorMessage: string;
  }
| { type: "auto_retry_end"; success: boolean; attempt: number; finalError?: string }
```

Pi extension docs describe `ctx.ui` as the extension user-interaction surface:

- `ctx.ui.confirm`
- `ctx.ui.select`
- `ctx.ui.input`
- `ctx.ui.editor`
- `ctx.ui.notify`
- `ctx.ui.custom`
- editor/footer/widget/theme customization APIs

The examples include a permission-gate extension using `ctx.ui.select` for a
dangerous command and a questionnaire extension using `ctx.ui.custom`.

## Runtime Event Mapping Plan

Implement these mappings after the rich event envelope exists.

`queue_update`

- Emit `queue_updated`.
- `steeringCount = event.steering.length`.
- `followUpCount = event.followUp.length`.
- `steeringPreview` and `followUpPreview` should include at most the first 3
  strings from each queue.
- Do not emit full queued prompt text if it may contain secrets. Consider
  truncating each preview string to 160 characters.

`auto_retry_start`

- Emit `auto_retry_updated` with:
  `phase = "started"`, `attempt`, `maxAttempts`, `delayMs`, and
  `errorMessage`.
- Also update activity state if a visible activity row already represents the
  failed turn.

`auto_retry_end`

- Emit `auto_retry_updated` with:
  `phase = "ended"`, `attempt`, `success`, and `finalError`.
- If `success = false`, also emit `provider_warning` with `level = "error"`.

`thinking_level_changed`

- Keep the existing `runtime_updated` behavior.
- Add a test proving the runtime field changes for Pi sessions.
- Do not add a separate live event unless mobile needs a transient animation.

`compaction_start` and `compaction_end`

- Keep the existing context-compaction activity behavior.
- Confirm mobile shows compaction progress in Pi sessions, because the original
  issue was lack of visible context-window/compaction feedback.
- If compaction end includes `errorMessage`, emit `provider_warning`.

## Adapter Implementation Steps

1. Add `case "queue_update"` to `handleSessionEvent` in `src/pi-provider.ts`.
2. Add `case "auto_retry_start"` and `case "auto_retry_end"`.
3. Use the provider-neutral event shapes from
   `01-rich-event-envelope.md`.
4. Add local helpers:
   `emitPiQueueUpdated`, `emitPiAutoRetryStarted`, and
   `emitPiAutoRetryEnded`.
5. Keep runtime telemetry replacement logic untouched unless tests show stale
   values.
6. Add fake Pi session fixtures to cover queue and retry events.
7. Verify `MultiAgentProvider` namespaces Pi event session IDs.

## Extension UI Bridge Decision

Pi `ctx.ui` is richer than the current Sidemesh pending-action contract.
Implement this in layers.

Layer 1: classify support

- `ctx.ui.notify` maps to `provider_warning` or info activity.
- `ctx.ui.confirm` maps to `PendingActionKind = "user_input"` only if Pi's
  extension runner exposes a resolvable request boundary to the SDK user.
- `ctx.ui.select` maps to `PendingActionKind = "user_input"` with choices.
- `ctx.ui.input` maps to `PendingActionKind = "user_input"` with freeform.
- `ctx.ui.editor` is not supported in first version unless mobile can present a
  multiline editor and round-trip the result.
- `ctx.ui.custom` is not supported in first version. It is arbitrary TUI code,
  not a portable mobile form schema.
- Footer/widget/theme/editor customization APIs are not portable pending
  actions. Treat them as unsupported or provider-local UI.

Layer 2: verify SDK hook point

- Confirm whether `@earendil-works/pi-coding-agent` exposes an `ExtensionUIContext`
  injection point when used as a library.
- If the provider adapter can inject a custom UI context, implement a
  Sidemesh-backed UI context.
- If the adapter cannot inject a UI context without patching Pi, document this
  as upstream work and keep interaction capabilities false.

Layer 3: implement portable UI methods

- Convert `confirm`, `select`, and `input` into pending actions.
- Use provider-private metadata to store the Pi UI request ID and resolver.
- Resolve the original Pi promise from `respondToPendingAction`.
- Add timeouts/cancellation when the session ends.

Layer 4: explicitly reject non-portable UI

- For `custom`, `setFooter`, `setWidget`, `setEditorComponent`, theme changes,
  and autocomplete changes, emit a `provider_warning` saying the mobile bridge
  does not support this Pi extension UI method.
- Do not pretend these succeeded unless Pi extensions require a no-op for
  compatibility. If no-op is required, surface a warning.

## Capability Flip Plan

Keep `PI_PROVIDER_CAPABILITIES.interaction.userInput = false` until:

- The Pi SDK UI injection point is confirmed.
- `confirm`, `select`, and `input` are implemented and tested.
- Session-end cancellation resolves pending Pi UI promises safely.

Keep `PI_PROVIDER_CAPABILITIES.interaction.elicitation = false` unless Pi
exposes a structured schema equivalent to MCP elicitation. Pi `ctx.ui.custom`
should not be called elicitation because it is executable/custom TUI UI, not a
portable form schema.

## Mobile Implementation Steps

From the rich event envelope:

- Render `queue_updated` near the composer or session header.
- Render `auto_retry_updated` as activity/warning state.
- Verify Pi compaction and context usage remain visible in the runtime strip.
- If Pi user input is later enabled, reuse the existing pending-action card.

No mobile provider-specific Pi UI should be added for `ctx.ui.custom` in first
version.

## Test Plan

Pi provider tests:

- `queue_update` emits `queue_updated` with counts and truncated previews.
- `auto_retry_start` emits `auto_retry_updated`.
- `auto_retry_end` emits `auto_retry_updated`.
- Failed `auto_retry_end` emits `provider_warning`.
- `thinking_level_changed` still emits `runtime_updated`.
- `compaction_end` with error emits warning if implemented.

Server tests:

- Pi queue and retry events broadcast only to the owning session.
- Multi-provider Pi session IDs are namespaced.

Mobile tests:

- Queue indicator parses and renders.
- Retry state parses and renders.
- Pi runtime strip shows context/compaction data when present.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Queue previews may expose user prompt content. Truncate and consider hiding
  preview text behind a setting.
- `ctx.ui.custom` is not portable. Trying to serialize arbitrary TUI components
  into mobile will create a brittle provider-specific client surface.
- If Pi extension UI promises are not resolved on session close, extensions may
  hang. Cancellation handling is mandatory before flipping capabilities.

## Acceptance Criteria

- Pi sessions expose queue and retry state through typed live events.
- Pi context/compaction visibility is preserved or improved.
- Pi interaction capabilities remain false unless portable `ctx.ui` methods
  truly round-trip.
- Unsupported Pi extension UI paths fail visibly and do not hang the session.
