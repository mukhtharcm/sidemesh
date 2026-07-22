# Provider access modes

Status: architecture decision and implementation note for PR #331.

Updated: 2026-07-22.

## Decision

Sidemesh will present access as a provider-owned capability, not as a universal
set of sandbox switches. Shared clients receive a small catalog of display-ready
access modes with opaque IDs. The selected provider adapter owns the translation
from that ID to its native execution settings.

Sidemesh host security remains a separate boundary. Workspace roots, file APIs,
terminals, browser sessions, and other host-owned features continue to enforce
their own rules regardless of the selected agent provider.

Working native adapters will remain in the product. ACP is an additional adapter
path, not a reason to remove a native integration before it can demonstrate
equivalent behavior.

## Why the old abstraction was misleading

The previous shared UI assumed that every provider could be described by three
controls: approval policy, file access, and network access. Those concepts do not
line up consistently across providers:

- some providers expose named permission profiles;
- some return an approval choice for each requested action;
- some use granular rules and remembered patterns;
- some intentionally provide no sandbox or approval layer;
- ACP agents supply their own ordered approval options with opaque IDs.

Combining those systems into common booleans made the UI look configurable even
when the daemon could not preserve the provider's real semantics. It also made
autonomy look equivalent to unrestricted machine access. They are distinct and
must remain distinct.

## Contract implemented in PR #331

Providers can now advertise two explicit capabilities:

- `configuration.accessModes`: the provider can describe the access modes valid
  for a workspace;
- `runtimeControls.accessMode`: the provider accepts an opaque access-mode ID on
  session creation or the next turn.

`listAccessModes` returns display-ready entries containing:

- an opaque ID;
- label and short description;
- a semantic icon hint and tone;
- enabled state and an optional unavailable reason;
- optional provider-authored confirmation copy;
- the provider's default mode.

The shared Flutter client never receives or reconstructs a provider-native
permission tuple. It stores and sends only the opaque access-mode ID. The daemon
validates the capability, and the selected adapter resolves the ID immediately
before calling its provider.

The previous permission fields and endpoint remain temporarily for clients and
daemons released before this contract. New UI does not depend on them.

## Provider behavior

### Codex

The native adapter can discover the effective permission profiles, reviewer
availability, managed requirements, feature state, and configured defaults. It
publishes a concise mode catalog and translates the selected ID back into the
native values internally.

The first catalog includes choices such as asking for approval, provider-assisted
review, read-only operation when supported, full access, and the provider's own
configuration. Full access carries provider-authored danger copy and requires a
confirmation. Provider-assisted review never implies full machine access.

### Copilot

The native adapter preserves action-level approval requests and their available
scopes. Agent mode remains separate from access. Sidemesh should not add a global
access selector until the adapter can describe an accurate, effective policy
without flattening tool, path, and URL rules.

### OpenCode

The native adapter preserves the approval options actually offered for an
action. Remembered pattern decisions must use the provider's meaning rather than
a Sidemesh-invented duration. A future global access summary should describe the
effective provider configuration, not generic file and network toggles.

### Pi

No provider access selector is shown because the provider does not expose a
runtime permission layer. If Sidemesh later offers isolation for these sessions,
it must be implemented and labelled as a real host-owned boundary.

### ACP

ACP remains a generic extension path. Approval requests must render the ordered
option IDs, labels, and semantic kinds supplied by the selected agent. Gateway
policy and individual action approval are separate concepts.

### Fake provider

The fake provider remains a development-only harness. It should cover contract
and capability combinations without appearing in normal setup.

## Native adapter and ACP policy

A native adapter may be replaced only after an explicit parity review. The ACP
path must match every behavior Sidemesh depends on, including:

1. session discovery, creation, resume, rename, archive, and history fidelity;
2. streaming events, stable item identity, replay, and reconnect behavior;
3. approval option meaning, scope, cancellation, and pending-action recovery;
4. models, reasoning controls, profiles, modes, and skills where supported;
5. attachments, file mentions, child sessions, plans, diffs, and usage data;
6. interruption, compaction, provider restart, errors, and version reporting;
7. multi-host operation and recovery after the mobile client disconnects.

Until that matrix passes, retaining the native adapter is the safer and more
capable choice. New providers can use ACP when its contract already covers their
needs; provider-specific code should be added only for a concrete capability gap.

## UI rules

- Show one compact `Access` row only when the selected provider advertises it.
- Use provider-authored labels and explanations; do not expose wire-level names.
- Keep access, agent mode, and thinking effort as separate concepts.
- Without an access-mode catalog, show only the individual runtime controls the
  provider explicitly advertises; never synthesize a broader access mode.
- Hide unsupported controls instead of showing disabled generic settings.
- Use a normal adaptive settings surface for multi-row choices, not a large
  floating dialog.
- Keep dangerous choices visually quiet until selected, then show a direct
  confirmation with the real consequence.
- Inherit the source session's opaque access mode when it remains valid for the
  new workspace; otherwise fall back to the current provider default.
- Preserve readable line lengths and compact row density on both phone and
  desktop layouts.

## Follow-up order

1. Finish the opaque access-mode rollout and compatibility tests.
2. Preserve provider-supplied approval option IDs and semantics end to end.
3. Correct any adapter whose remembered approval scopes are currently flattened.
4. Add provider-owned effective summaries only where the provider can supply
   truthful state.
5. Expand fake-provider coverage for unavailable modes and confirmations.
6. Revisit native-to-ACP migration only through the parity matrix above.
