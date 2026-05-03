# Provider-Neutral Search UX Implementation Plan

## Goal

Turn the current session search implementation into a provider-neutral,
diagnosable search feature that works across Codex, Copilot, Pi, fake provider,
and future providers.

The feature should let users find sessions by text, provider, workspace, time,
and archived state without knowing which provider created the session.

## Current State

- `src/session-search-index.ts` implements an SQLite FTS5 index.
- `src/server.ts` exposes `/api/sessions/search`.
- `src/types.ts` adds `matchSnippet` to `SessionSummary`.
- `apps/mobile/lib/src/api_client.dart` calls `/api/sessions/search`.
- `apps/mobile/lib/src/screens/home_screen.dart` searches across hosts and
  displays `matchSnippet`.
- Startup catch-up currently indexes a limited set of unarchived sessions from
  provider history.
- `src/server.ts` indexes a session after relevant live events and session
  mutations.
- Search is currently mostly text + limit. It does not expose provider,
  workspace, date, archived, or host diagnostics as first-class filters.

## Evidence Anchors

- `src/session-search-index.ts:211` defines `SessionSearchIndex`.
- `src/session-search-index.ts:233` currently contains a manifest drop path
  that must be reviewed on the implementation branch.
- `src/session-search-index.ts:342` defines catch-up behavior.
- `src/session-search-index.ts:424` exposes index stats.
- `src/server.ts:201` constructs the search index.
- `src/server.ts:714` exposes search capability/stats on `/api/node`.
- `src/server.ts:846` defines `/api/sessions/search`.
- `src/server.ts:861` calls `searchIndex.search`.
- `src/server.ts:870` attaches `matchSnippet`.
- `src/server.ts:2275` opens and warms the search index.
- `src/server.ts:2787` indexes generic provider sessions.
- `apps/mobile/lib/src/api_client.dart:129` calls search from Flutter.
- `apps/mobile/lib/src/screens/home_screen.dart:1136` searches from home.
- `apps/mobile/lib/src/screens/home_screen.dart:1688` renders snippets.
- `apps/mobile/lib/src/models.dart:509` includes `matchSnippet`.

## Known Issues And Gaps

Index persistence:

- Review `src/session-search-index.ts` startup schema handling. The current
  implementation includes a `DROP TABLE IF EXISTS session_manifest` path in
  `open()`, which defeats long-lived manifest caching if still present on the
  target branch.
- The search index needs schema versioning rather than unconditional table
  drops.

Backfill coverage:

- Startup catch-up currently indexes a small page of recent unarchived sessions.
- Older sessions can remain missing until touched.
- Archived sessions need an explicit policy.

Metadata filters:

- Search results have `sessionId` and snippet, but efficient provider/cwd/date
  filters need a side table with normalized metadata.
- Multi-provider session IDs are namespaced. The index should store both the
  public session ID and normalized provider kind when known.

Diagnostics:

- `/api/node.searchIndexStats` exists, but it should be expanded into useful
  per-provider stats: indexed count, last indexed time, backfill progress,
  last error, and whether FTS is available.

Mobile UX:

- Home search shows snippets, but users cannot filter by provider or workspace.
- Host detail and inspector search are separate concepts. Users need clear
  labels so "session search" and "within-session transcript search" do not feel
  like the same control.

Provider support:

- Providers with history and log APIs can be indexed by the host.
- Providers without history/log support should still advertise that search is
  unavailable or partial.
- Pi currently advertises `searchSessions = false`, so Pi search depends on
  whether Sidemesh can read Pi session logs through provider history APIs.

## Data Model Plan

Add a metadata table next to the FTS table:

```sql
CREATE TABLE IF NOT EXISTS session_search_documents (
  session_id TEXT PRIMARY KEY,
  provider_kind TEXT,
  title TEXT,
  preview TEXT,
  cwd TEXT,
  created_at INTEGER,
  updated_at INTEGER,
  archived INTEGER NOT NULL DEFAULT 0,
  next_seq INTEGER,
  fingerprint TEXT NOT NULL,
  indexed_at INTEGER NOT NULL,
  source TEXT NOT NULL
);
```

Keep the FTS table focused on searchable text:

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS session_search_fts
USING fts5(session_id UNINDEXED, content, tokenize = 'unicode61');
```

Add a schema version table:

```sql
CREATE TABLE IF NOT EXISTS session_search_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

Use this for migrations:

- `schema_version = 1`: current FTS-only index.
- `schema_version = 2`: metadata table and stable manifest persistence.

Do not drop manifest/index tables on every open. Only rebuild when the schema
version requires it or when integrity checks fail.

## API Plan

Extend `/api/sessions/search` query params:

- `q`: text query.
- `limit`: result limit.
- `provider`: optional provider kind.
- `cwd`: optional workspace path or prefix.
- `archived`: optional `true`, `false`, or `all`.
- `updatedAfter`: optional epoch milliseconds or ISO timestamp.
- `updatedBefore`: optional epoch milliseconds or ISO timestamp.
- `cursor`: optional opaque cursor for pagination.

Return shape can remain `SessionSummary[]` at first, but a richer response is
better for pagination and diagnostics:

```ts
{
  sessions: SessionSummary[];
  nextCursor?: string;
  partial: boolean;
  warnings?: string[];
}
```

Compatibility path:

- Keep the old array response if the client does not opt into v2.
- Or add `/api/sessions/search2` for the richer response.
- Prefer one endpoint with backward-compatible response only if the mobile
  parser can handle both.

## Indexing Plan

Index document source:

- Use `provider.listSessionThreads` for session metadata.
- Use `provider.readSessionLog` for searchable transcript text.
- Use `nextSeq` from log metadata for incremental fingerprinting.
- Include title, preview, cwd, archived, createdAt, and updatedAt in the
  fingerprint so metadata-only changes re-index.

Backfill:

- Replace one-time "recent 50" catch-up with paginated background catch-up.
- Add a configurable batch size, for example 50 sessions per tick.
- Yield between batches so daemon startup remains fast.
- Track per-provider backfill cursor or watermark in `session_search_meta`.
- Expose backfill state in stats.

Stale cleanup:

- When a provider reports archived/deleted sessions, update or remove rows.
- If a provider cannot list a session that exists in the index, mark it stale
  only after a second confirmation to avoid deleting during transient provider
  failures.

Failure handling:

- If one provider fails during catch-up, keep other provider indexing alive.
- Store last error per provider for diagnostics.
- Search should return `partial = true` if a provider index is known stale or
  failed.

## Ranking And Snippets

First-pass ranking:

- Use FTS5 rank for text relevance.
- Break ties with `updated_at DESC`.
- Prefer exact title matches over transcript-only matches if practical.

Snippets:

- Continue returning `matchSnippet`.
- Strip control characters.
- Keep snippets short enough for mobile cards.
- Highlighting can be done by mobile later; do not return HTML from the daemon.

Empty or operator-only queries:

- Preserve the existing fix where empty FTS expressions return `[]`.
- If filters are provided with empty `q`, decide whether that means "browse
  filtered sessions" or "no search". For mobile, filtered browse is useful, but
  implement it explicitly and test it.

## Mobile UX Plan

Home search:

- Add provider filter chips using `node.supportedProviders`.
- Add workspace filter from recent session `cwd` values.
- Add archived toggle: active only, archived only, all.
- Keep cross-host search, but surface per-host partial failures as a small
  warning rather than silently ignoring all errors.
- Display provider kind/name on search result cards when multi-provider mode is
  active.

Host detail:

- Add a search entry point scoped to one host.
- Show index health from `/api/node.searchIndexStats`.
- If search is partial or backfilling, show "indexing..." with last indexed
  time.

Session inspector:

- Keep transcript-in-session search separate.
- Label it as "Find in this session" to avoid confusion with global session
  search.

## Provider-Specific Plan

Codex:

- History/log APIs are already strong enough for indexing.
- Ensure thread updated time, title, cwd, preview, and archived status are
  included in the metadata fingerprint.

Copilot:

- Confirm `listSessionThreads` and `readSessionLog` return enough transcript
  text and metadata.
- Add tests for metadata-only updates because Copilot titles/previews can
  change without transcript seq changing.

Pi:

- Pi currently advertises session search as false.
- Research whether the Pi provider adapter can expose `listSessionThreads` and
  `readSessionLog` from Pi session manager data.
- If yes, flip Pi search support only after indexing tests pass.
- If not, keep Pi excluded and report search as partial when Pi sessions are
  present.

Fake provider:

- Add deterministic fixtures for title-only, preview-only, cwd-only,
  archived, deleted, and transcript matches.

## Test Plan

Index tests:

- Metadata table migration preserves existing indexed rows.
- Opening the index does not drop manifest rows.
- Metadata-only changes re-index.
- Empty FTS query returns `[]` or filtered browse results based on the chosen
  API semantics.
- Provider filter works.
- CWD filter works.
- Date filters work.
- Archived filter works.
- Pagination is stable.
- Stale cleanup does not delete rows on one transient provider error.

Server tests:

- `/api/sessions/search` or `/api/sessions/search2` validates all query params.
- Multi-provider search returns provider-scoped sessions correctly.
- Partial provider failure returns warnings/partial status without failing the
  entire request.
- `/api/node.searchIndexStats` includes useful provider-level stats.

Mobile tests:

- `ApiClient.searchSessions` supports filters and richer response.
- Home search filter chips construct the expected query.
- Search results show snippets and provider names.
- Partial host/provider failures render a non-blocking warning.
- Legacy array response still parses if compatibility is kept.

Required gates:

- `npm run typecheck`
- `npm run test:server`
- `cd apps/mobile && flutter test`
- `cd apps/mobile && flutter analyze`

## Risks

- Search index migrations can destroy user search history if implemented with
  table drops. Use schema versioning and backup/rebuild logic.
- Backfilling every session at startup can slow daemon start. Run it in the
  background with bounded batches.
- Cross-provider search can leak provider implementation details if result IDs
  are not consistently namespaced.
- Snippets can expose sensitive transcript content on the home screen. Keep
  snippets short and respect future privacy settings.

## Acceptance Criteria

- Search works across all providers that expose history/log APIs.
- Users can filter by provider, workspace, archived state, and update time.
- Search index stats explain whether results are complete or partial.
- Mobile search results are understandable in multi-host and multi-provider
  setups.
- Opening the daemon no longer resets the manifest/index without a migration
  reason.
