# Session synchronization

The daemon uses each provider's session snapshot as the recovery contract. The
mobile app fetches `/api/sessions/:id/log` on open, WebSocket connection, app
resume, manual refresh, and shortly after turn completion. WebSocket events keep
ongoing replies, tools, approvals, and plans responsive between reads.

The log endpoint returns recent messages and activities, session/runtime status,
pending approval, latest plan, active assistant text/reasoning, and history counts.
Message and activity limits default to 200. Clients request larger windows when
loading older history. A cached transcript remains marked stale until a snapshot
succeeds, including when the provider's timestamp has not changed.

`SessionStateStore` owns current turns, observed status, activities, runtime,
partial output, and transcript ordering. Provider history remains durable storage;
provider-specific parsers and recovery sidecars remain inside their adapters.
`StateWriter` coalesces Pi and Copilot persistence requests and only acknowledges
requests after their snapshot is saved. Copilot closes its SDK and flushes before
shutdown completes.

## Events during a refresh

`seq` orders transcript items; it is not a freshness cursor. `revision` is an
in-memory counter used only to distinguish events covered by an in-flight
snapshot from events arriving afterward. It is never persisted by the client or
used to decide whether to refresh after reconnecting.

The server finishes provider reads before capturing the live overlay and its
revision. The client buffers events while fetching, installs the snapshot's
partial text, and applies later deltas. Covered completed messages are preserved
while provider history flushes, without replaying old draft/status transitions.
Finished tool overlays remain until the provider snapshot confirms their content
(or another turn begins), so a completion cannot erase updates from a read
already in progress. Warnings, queue changes, and retry notifications remain observable. A failed
request drains buffered events and preserves the existing conversation.

## Coordinated upgrade

Upgrade the daemon and app together, between turns after pending sends have
settled. This change removes `/api/sessions/:id/events`, the independent Codex
replay parser, legacy input signatures, `text`/`prompt` request aliases, the
`sandbox` turn alias, the permission-profile HTTP catalog, and the
`providerCapabilities`/`codexVersion` metadata aliases. Create/send requests use
structured `input`, `sandboxMode`, and opaque `accessMode`. Native Codex permission
profiles remain an adapter detail. Actual provider capabilities remain in use.

Existing input receipts are retained; incompatible signatures reject reused IDs
instead of risking a duplicate submission. Incompatible SQLite search caches are
rebuilt from provider history. Session history and provider recovery files are
not reset.

## Tradeoffs and checks

Recovery transfers a recent snapshot instead of a delta. Responses stay limited
to a recent window, but a provider may scan its full history to assemble it. If
that becomes expensive, optimize that provider's snapshot reader rather than
adding a second history protocol.

Regression coverage includes real Pi HTTP recovery after partial file appends,
concurrent snapshots, bounded history and loading older rows, branch changes,
live text arriving during refresh, approval recovery, coarse timestamps, cached
content, persistence failures, and Copilot shutdown. The provider routing and
host filesystem, terminal, browser, and updater boundaries remain intact.
