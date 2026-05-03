# Codex Interaction Bridge Implementation Plan

## Goal

Make Codex-owned interaction requests first-class Sidemesh pending actions.
Specifically:

- Map Codex `item/tool/requestUserInput` into `PendingActionKind =
  "user_input"`.
- Map Codex `mcpServer/elicitation/request` into `PendingActionKind =
  "elicitation"`.
- Return correctly shaped JSON-RPC responses to Codex when the mobile user
  answers, declines, or cancels.
- Flip Codex `capabilities.interaction.userInput` and
  `capabilities.interaction.elicitation` only after the full request/response
  loop is tested.

## Current State

- `src/agent-provider.ts` already models interaction capabilities:
  `interaction.userInput` and `interaction.elicitation`.
- `src/types.ts` already models public pending actions for
  `"user_input"` and `"elicitation"`.
- `src/approvals.ts` already parses mobile responses for both kinds:
  `{ answer, wasFreeform }` for user input and
  `{ action, content? }` for elicitation.
- `apps/mobile/lib/src/models.dart` already parses `PendingAction.userInput`
  and `PendingAction.elicitation`.
- `apps/mobile/lib/src/screens/session_screen_header.dart` already renders the
  user-input and elicitation pending-action UI.
- `src/copilot-provider.ts` already has working user-input and elicitation
  pending-action patterns.
- `src/codex-provider.ts` currently maps only command, file change, and
  permissions approval requests in `emitCodexServerRequest`.
- `CODEX_PROVIDER_CAPABILITIES.interaction.userInput` and
  `CODEX_PROVIDER_CAPABILITIES.interaction.elicitation` are currently `false`.

## Evidence Anchors

- `src/agent-provider.ts:204` defines `interaction.userInput` and
  `interaction.elicitation`.
- `src/types.ts:435` includes `PendingActionKind = "elicitation"`.
- `src/approvals.ts:78` parses elicitation responses.
- `src/approvals.ts:175` preserves public elicitation payloads.
- `apps/mobile/lib/src/models.dart:2024` parses `PendingAction.userInput`.
- `apps/mobile/lib/src/models.dart:2025` parses `PendingAction.elicitation`.
- `apps/mobile/lib/src/screens/session_screen_header.dart:1463` reads
  user-input actions.
- `apps/mobile/lib/src/screens/session_screen_header.dart:1469` reads
  elicitation fields.
- `src/codex-provider.ts:665` handles Codex server requests.
- `src/codex-provider.ts:1882` defines Codex capabilities.
- `src/codex-provider.ts:1904` currently leaves elicitation disabled.
- `src/codex-provider.ts:1937` builds Codex pending-action responses.
- Codex protocol `common.rs:1226` defines `item/tool/requestUserInput`.
- Codex protocol `common.rs:1232` defines `mcpServer/elicitation/request`.
- Codex protocol `v2.rs:7211` defines MCP elicitation params.
- Codex protocol `v2.rs:7603` defines MCP elicitation response.
- Codex protocol `v2.rs:7740` defines tool user-input params.
- Codex protocol `v2.rs:7759` defines tool user-input response.

## Codex Protocol Evidence

Codex app-server protocol includes these JSON-RPC server requests:

- `item/tool/requestUserInput`
- `mcpServer/elicitation/request`

In Codex `v2.rs`, `ToolRequestUserInputParams` includes:

- `thread_id: String`
- `turn_id: String`
- `item_id: String`
- `questions: Vec<ToolRequestUserInputQuestion>`

Each `ToolRequestUserInputQuestion` includes:

- `id`
- `header`
- `question`
- `is_other`
- `is_secret`
- optional `options`

The response is:

```ts
{
  answers: Record<string, { answers: string[] }>;
}
```

Codex MCP elicitation params include:

- `thread_id`
- optional `turn_id`
- `server_name`
- flattened request with `mode: "form"` or `mode: "url"`

Form mode includes:

- `message`
- `requested_schema` with object properties for string, number, boolean,
  single-select enum, and multi-select enum.

URL mode includes:

- `message`
- `url`
- `elicitation_id`

The response is:

```ts
{
  action: "accept" | "decline" | "cancel";
  content?: unknown;
  _meta?: unknown;
}
```

## Data Model Plan

Do not add Codex-specific public types. Reuse the existing pending-action
contract:

- `PendingActionKind = "user_input"` for tool input.
- `PendingActionKind = "elicitation"` for MCP elicitation.
- Store Codex-only request metadata in provider-private fields on the action.
- Keep public payloads under `userInput` and `elicitation`.

Add or confirm private action metadata shape in `src/codex-provider.ts`:

```ts
type CodexPendingActionPrivate = {
  provider: "codex";
  requestId: string | number;
  method: string;
  threadId?: string;
  turnId?: string;
  itemId?: string;
  questionIds?: string[];
};
```

The private shape does not need to be exported unless tests need a local helper.
`toPublicPendingAction` in `src/approvals.ts` should continue stripping this
private data.

## User Input Mapping

Add `buildCodexUserInputAction(requestId, params)` in
`src/codex-provider.ts`.

Rules:

- Reject malformed params with a warning and a safe JSON-RPC error response
  rather than emitting a broken pending action.
- If there is exactly one question, map it directly to the public
  `PendingActionUserInputRequest`.
- If there are multiple Codex questions, first implementation should combine
  them into one prompt only if the mobile UI cannot handle multiple fields.
  Prefer a follow-up schema extension for multi-question support rather than a
  lossy concatenation.
- `question` should use Codex `question`, with `header` folded into the title or
  subtitle if useful.
- `choices` should map each Codex option to `{ label, description }`.
- `allowFreeform` should be true when `is_other` is true or no options exist.
- `is_secret` should not be ignored. If mobile cannot securely hide input yet,
  return a provider warning and decline the request rather than displaying a
  plaintext secret prompt.

Recommended first-pass behavior for multi-question requests:

- Support one question fully.
- For multiple questions, emit `provider_warning` and answer with a controlled
  failure only after confirming Codex accepts error responses for the server
  request. If Codex requires a normal response, block implementation until the
  public Sidemesh pending-action schema supports multiple user-input fields.

## Elicitation Mapping

Add `buildCodexElicitationAction(requestId, params)`.

Rules:

- `source` should be `server_name`.
- `mode: "url"` maps to public elicitation URL mode with `message` and `url`.
- `mode: "form"` maps `requested_schema.properties` into
  `PendingActionElicitationField[]`.
- Preserve required fields from the schema.
- Map string, number, boolean, single-select enum, and multi-select enum.
- Unsupported schema fragments should either be rendered as text fields with a
  warning or declined with a clear `provider_warning`. Prefer explicit decline
  for unknown required fields.
- Do not expose raw MCP `_meta` to mobile unless a product use-case needs it.
  Keep it in private metadata if it must round-trip.

Field normalization should mirror the Copilot helpers where possible. If the
Copilot normalizer is generic enough, extract it into a small shared helper such
as `src/elicitation-fields.ts`; otherwise keep Codex and Copilot translation
separate to avoid overfitting either protocol.

## Response Serialization Plan

Extend `buildCodexActionResponse(action, decision)` in
`src/codex-provider.ts`.

For `user_input`:

- Parse `decision.userInput.answer`.
- Map back to Codex response:

```ts
{
  answers: {
    [questionId]: { answers: [answer] }
  }
}
```

- If the user selected an option, send the option label or stable value Codex
  expects. Confirm against live Codex behavior before finalizing; the protocol
  names the field `answers`, not `optionIds`.
- If the user cancels, use the least surprising response Codex supports. If no
  cancel response exists for user input, answer with an empty string only if
  Codex treats that as cancellation; otherwise return JSON-RPC error.

For `elicitation`:

- Map `PendingActionResponseDraft.elicitation(action: "...")` directly to
  Codex `action`.
- Include `content` only for `accept`.
- Do not include `content` for `decline` or `cancel`.
- Preserve `_meta` only if Codex requires it for URL-mode completion.

## Server Flow

The existing server flow should mostly work:

- Provider emits `action_opened`.
- `src/server.ts` stores it in `pendingActions`.
- Mobile sends `/api/actions/:actionId/respond`.
- `parsePendingActionResponseBody` returns the normalized decision.
- `provider.respondToPendingAction(action, decision)` calls Codex.
- Server broadcasts `action_resolved`.

The implementation should verify this whole loop with Codex action kinds, not
only Copilot.

## Capability Flip Plan

Only flip `CODEX_PROVIDER_CAPABILITIES.interaction.userInput` to `true` after:

- Single-question non-secret user input works end-to-end.
- Option choice and freeform input both serialize correctly.
- Tests cover malformed params and missing question IDs.

Only flip `CODEX_PROVIDER_CAPABILITIES.interaction.elicitation` to `true` after:

- URL-mode elicitation works.
- Form-mode string, number, boolean, single-select, and multi-select fields
  round-trip.
- Decline and cancel responses are tested.

## Test Plan

Codex provider tests:

- `item/tool/requestUserInput` emits a public `user_input` pending action.
- Response serialization returns the expected Codex `answers` map.
- Freeform user input is preserved.
- Option selection maps to the expected answer string.
- Secret input is rejected or handled by a secure UI path.
- `mcpServer/elicitation/request` URL mode emits `elicitation` action.
- MCP form mode maps schema fields correctly.
- Accept, decline, and cancel serialize correctly.
- Malformed params do not crash the daemon.

Server tests:

- `/api/actions/:actionId/respond` routes Codex `user_input` and `elicitation`
  actions through `respondToPendingAction`.
- `action_opened` and `action_resolved` are broadcast.
- Multi-provider action IDs remain namespaced.

Mobile tests:

- Existing user-input and elicitation UI should pass unchanged.
- Add a Codex-shaped fixture to prove the public payload is provider-neutral.
- If secret user input is supported, add an obscured text entry test.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Codex user input supports multiple questions, while the current Sidemesh
  public user-input shape is single-question. Do not silently collapse multiple
  questions into ambiguous text.
- Secret questions need explicit secure UI handling. Plaintext display would be
  a security regression.
- MCP schema support can expand. Unknown required fields must fail safely.
- Codex request/response protocol may change. Confirm against the pinned Codex
  app-server protocol before implementing.

## Acceptance Criteria

- Codex advertises `interaction.userInput` and `interaction.elicitation`.
- A live Codex tool user-input request appears in mobile as a pending action and
  the response reaches Codex.
- A live Codex MCP elicitation request appears in mobile and accept/decline/cancel
  reaches Codex.
- Copilot interaction behavior is unchanged.
- Unknown or unsupported Codex interaction shapes fail visibly and safely.
