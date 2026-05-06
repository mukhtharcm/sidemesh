# Account Usage Observability Plan

## Goal

Add a generic usage-observability layer that lets each host report quota and usage observations, while the client reconciles those observations into account-level cards. The feature must not be tied to a single provider and must support future providers with different quota models, identities, reset windows, credits, or local-only telemetry.

## Product Principles

- Usage is account/subscription scoped, not host scoped. Multiple hosts using the same account should collapse into one account card.
- Hosts are collectors. The client reconciles observations from all enabled hosts.
- Providers expose normalized observations through a generic contract.
- Unknown or unsupported providers should be explicit, not look broken.
- Local telemetry and authoritative quota limits are separate concepts.
- Raw account identifiers should not be exposed unless they are already user-visible and safe; stable hashes and masked labels are preferred.

## Data Model

Hosts expose `UsageObservation` records. A record represents one observation of a quota bucket, subscription, account, API key, workspace, organization, or local telemetry source.

Core fields:

- `id`: stable observation id within a host response.
- `hostId`, `hostLabel`: collector identity.
- `observedAt`: timestamp when the source was read.
- `expiresAt`: optional TTL deadline.
- `provider`: provider kind, display name, and optional upstream provider labels.
- `account`: optional account metadata such as masked label, account hash, email hash, organization hash, and plan type.
- `subject`: the reconciled usage subject such as account, organization, workspace, API key, subscription, model provider, local telemetry, or unknown.
- `windows`: normalized usage windows with percentage, reset time, and display labels.
- `credits`: optional credit balance or unlimited marker.
- `totals`: optional token/request/cost totals for local telemetry.
- `health`: ok, stale, unsupported, unauthorized, unavailable, or error.
- `source`: provider-owned source metadata.

The client groups observations by a reconciliation key:

```text
provider.kind + subject.kind + subject.stableKeyHash
```

If a stable subject hash is unavailable, the client falls back to:

```text
provider.kind + hostId + source.id
```

This avoids accidental merging of unrelated accounts.

## Backend Plan

1. Add generic usage types in `src/types.ts`.
2. Add optional provider capability metadata for usage features.
3. Add optional provider method `readUsageObservations()` to `src/agent-provider.ts`.
4. Add `GET /api/usage` in `src/server.ts`.
5. Add multi-provider fan-out support in `src/multi-provider.ts`.
6. Implement the first authoritative collector for the Codex provider using its local account/rate-limit RPC.
7. Add lightweight unsupported observations for providers that do not yet expose account limits.
8. Preserve provider-specific details inside provider adapters; server and client consume only normalized usage records.

## Provider Rollout

### Codex

- Query local account metadata.
- Query account rate limits.
- Normalize primary and secondary windows.
- Include reset timestamps, window durations, plan type, credits, and masked account labels when available.
- Reuse passive token-event rate-limit updates as a later optimization, not as the initial source of truth.

### Pi

- Do not model Pi as one quota account.
- Initially return unsupported or local telemetry observations only.
- Future work can emit downstream model-provider telemetry when Pi exposes reliable attribution.

### Copilot

- Defer collector implementation.
- Keep the schema ready for GitHub/Copilot account or organization windows.
- If reset times are unavailable, emit usage windows without reset metadata.

## Client Plan

1. Add Dart usage models mirroring the host API.
2. Add an API client method for `/api/usage`.
3. Add a `UsageStore` that fetches all enabled hosts, caches last successful host observations, and exposes loading/error/stale state.
4. Add a `UsageReconciler` that groups observations by account/subject, chooses the freshest valid source per window, and tracks contributing hosts.
5. Add a reusable `UsagePane` that renders reconciled cards.
6. Add a mobile Usage top-level tab.
7. Add a desktop Usage surface without adding a fourth sidebar segment.

## Mobile UI

Add a top-level Usage tab beside Recent, Approvals, and Hosts. The screen contains:

- Limits: authoritative account/subscription/API key quota cards.
- Observed usage: local-only telemetry cards.
- Unsupported: hosts/providers that do not expose quota data yet.
- Refresh action and per-card freshness indicators.

Each account card shows:

- Provider icon/name and masked account label.
- Plan or subscription label when known.
- Latest source host and age.
- Other hosts that have seen the same account.
- Usage windows with used percent, remaining percent, reset time, and window duration.
- Credits when available.
- Clear unavailable/unauthorized/error messaging.

## Desktop UI

Do not add a fourth sidebar segment. Keep the existing sidebar sections unchanged.

Add a compact Usage action in desktop chrome, preferably near the sidebar header or footer. Selecting it opens the Usage dashboard in the detail pane. If a session is already selected, the Usage surface can replace the detail pane for the MVP. A keyboard shortcut can be added later.

Desktop states:

- No session selected: Usage dashboard can occupy the main detail pane.
- Session selected: opening Usage switches the detail pane to Usage and clears the active session selection.
- Host selected: opening Usage switches the detail pane to Usage and clears host selection.

## Refresh And Staleness

- Fetch on opening the Usage tab/surface.
- Provide manual refresh.
- Refresh every few minutes while visible.
- Cache successful observations per host for offline/stale display.
- Avoid aggressive background polling in the MVP.

Suggested freshness bands:

- Fresh: under 2 minutes.
- Warm: 2 to 15 minutes.
- Stale: over 15 minutes.
- Expired: over 1 hour or provider TTL.

## Conflict Rules

- For the same account key and window id, newest observation wins.
- Do not average quota percentages from different hosts.
- If hosts report incompatible identities or window shapes for the same key, show a conflict note but keep the newest value visible.
- If identity is not stable, do not merge across hosts.

## Acceptance Criteria

- Same account observed from multiple hosts appears as one card.
- The card identifies the newest source host and other contributing hosts.
- Reset times display when a provider supplies them.
- Providers without usage support are shown as unsupported, not broken.
- Pi does not pretend to expose one subscription limit.
- Desktop keeps the three existing sidebar sections.
- Mobile gets a discoverable Usage tab.
- The schema and UI remain provider-generic.
