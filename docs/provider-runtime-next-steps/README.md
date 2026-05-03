# Provider Runtime Next Steps

This folder is a handoff package for the remaining provider-runtime work after
`docs/provider-runtime-refactor-plan.md`.

Each note below has its own implementation plan because the work is easier to
land safely when split by provider/runtime surface:

1. [Rich event envelope](01-rich-event-envelope.md)
2. [Codex interaction bridge](02-codex-interaction-bridge.md)
3. [Copilot rich event cleanup](03-copilot-rich-event-cleanup.md)
4. [Pi runtime bridge](04-pi-runtime-bridge.md)
5. [Legacy surface cleanup](05-legacy-surface-cleanup.md)
6. [Provider-neutral search UX](06-provider-neutral-search-ux.md)

## Recommended Order

1. Land the rich event envelope first. Codex, Copilot, and Pi can then emit the
   same typed event shapes instead of inventing provider-specific payloads.
2. Land Codex interaction bridge next. It unlocks provider-owned MCP
   elicitation and tool user-input requests.
3. Land Pi runtime bridge and Copilot rich event cleanup independently. They
   should mostly add provider mappings and mobile rendering, not change core
   provider ownership.
4. Land provider-neutral search UX after the event work. Search is useful but
   larger because it touches storage, indexing, API filters, and mobile UI.
5. Land legacy cleanup last. It removes or de-emphasizes old compatibility
   surfaces only after the current client behavior is validated.

## Source References

Local Sidemesh anchors:

- Provider contract: `src/agent-provider.ts`
- Shared API types: `src/types.ts`
- Provider event forwarding and HTTP API: `src/server.ts`
- Multi-provider ID namespacing: `src/multi-provider.ts`
- Codex adapter: `src/codex-provider.ts`
- Copilot adapter: `src/copilot-provider.ts`
- Pi adapter: `src/pi-provider.ts`
- Pending action normalization: `src/approvals.ts`
- Search index: `src/session-search-index.ts`
- Mobile model parsing: `apps/mobile/lib/src/models.dart`
- Mobile live event handling: `apps/mobile/lib/src/screens/session_screen.dart`
- Mobile pending action UI:
  `apps/mobile/lib/src/screens/session_screen_header.dart`
- Mobile home search: `apps/mobile/lib/src/screens/home_screen.dart`

Provider source clones used for the research pass:

- Codex Rust protocol clone:
  `/tmp/sidemesh-provider-research/codex-rust-v0.128.0`
- Copilot SDK clone:
  `/tmp/sidemesh-provider-research/copilot-sdk`
- Pi monorepo clone:
  `/tmp/sidemesh-provider-research/pi-mono`

If those clones are missing, recreate them before implementation and confirm
the cited protocol shapes against the currently pinned package versions in
`package.json`.

## Evidence Index

Use these as starting points for implementation:

- `src/agent-provider.ts:184` defines provider capabilities.
- `src/agent-provider.ts:239` defines provider live events.
- `src/agent-provider.ts:361` defines the legacy provider filesystem surface.
- `src/types.ts:435` includes `PendingActionKind = "elicitation"`.
- `src/types.ts:609` carries public elicitation payload data.
- `src/server.ts:466` is the provider live-event forwarding switch.
- `src/server.ts:846` handles `/api/sessions/search`.
- `src/server.ts:2055` handles pending-action responses.
- `src/server.ts:2787` indexes generic provider sessions for search.
- `src/multi-provider.ts:82` wires provider live events in multi-provider mode.
- `src/codex-provider.ts:665` handles Codex JSON-RPC server requests.
- `src/codex-provider.ts:1882` defines Codex provider capabilities.
- `src/codex-provider.ts:1937` serializes Codex pending-action responses.
- `src/copilot-provider.ts:1316` handles Copilot user-input requests.
- `src/copilot-provider.ts:1335` handles Copilot elicitation requests.
- `src/pi-provider.ts:807` handles Pi session events.
- `apps/mobile/lib/src/models.dart:2515` defines mobile live-event parsing.
- `apps/mobile/lib/src/screens/session_screen.dart:2428` handles mobile live
  events.
- Codex protocol `common.rs:1226` defines `item/tool/requestUserInput`.
- Codex protocol `common.rs:1232` defines `mcpServer/elicitation/request`.
- Codex protocol `common.rs:1371` defines `turn/plan/updated`.
- Codex protocol `common.rs:1397` and `common.rs:1399` define reasoning deltas.
- Copilot SDK `generated/session-events.ts:740` defines
  `session.plan_changed`.
- Copilot SDK `generated/session-events.ts:1736` defines
  `assistant.reasoning_delta`.
- Pi `agent-session.ts:117` defines `queue_update`.
- Pi `agent-session.ts:132` and `agent-session.ts:133` define auto-retry
  events.

## Shared Guardrails

- Keep provider-specific protocol translation inside each provider adapter.
- Do not make Flutter assume a provider feature unless the daemon advertises it
  in capabilities or host capabilities.
- Preserve `/api/node.providerCapabilities` until the mobile compatibility
  cleanup is explicitly completed.
- Keep host-owned workspace features host-owned: filesystem browse/read/write,
  git, terminal, port forwarding, and browser preview.
- For TypeScript changes, run `npm run typecheck` before tests.
- For Flutter changes, run `cd apps/mobile && flutter analyze`.

## Definition Of Done

The full next-step package is complete when:

- Codex, Copilot, Pi, and fake provider tests cover every newly advertised
  provider capability or live-event shape.
- Server tests cover action routing, event forwarding, search API behavior, and
  multi-provider namespacing.
- Mobile models tolerate unknown provider data and render only supported
  capabilities.
- Documentation explains what is provider-owned, host-owned, legacy, and
  intentionally unsupported.
