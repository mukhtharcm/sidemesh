# Session storage and recovery

Native history belongs to the agent. Sidemesh stores local identity, archive
choices, input delivery records, and output that native history has not yet
confirmed. A successful native snapshot can replace a cache. It cannot remove
unconfirmed user data.

## Ownership

| Data | Owner and location |
|---|---|
| Provider settings and host access token | Existing restricted `config.json` |
| Native transcripts, branches, and credentials | The selected agent runtime |
| Instance aliases, local session metadata, input queue, receipts, plans, recovery | `STATE/sessions-v1.db`, using `node:sqlite` |
| Search results | Existing rebuildable search index |
| Client recent sessions, favorites, transcript cache, pending sends | Existing client `sidemesh_v1.db`, schema 4 |
| Client theme, selected controls, pins, and read state | Existing small preferences |
| Host connection credentials | Existing platform secure storage |

The host database uses WAL, full synchronous writes, foreign keys, and a
five-second busy timeout. Its file permissions are restricted before WAL files
are created. The database does not modify agent-owned history.

`session_items.authority` distinguishes required primary display data, recovery
data, and rebuildable cache data. `session_recovery` holds the coordinator's
unconfirmed live output. Provider adapters use native IDs and supported history
reads to establish confirmation. Similar message text alone cannot confirm a
client input or resolve divergent history.

## Input delivery

The host saves the input identity and payload before dispatch. Known unsent
queued inputs can resume after a daemon restart. An unknown send result remains
uncertain and cannot be resent automatically. Native acceptance is separate from
confirmation in durable native history. SQLite cannot make a remote agent action
and a local write one transaction.

The client outbox retains unsent input across database reopen. Capacity limits
reject new input instead of removing pending messages. Session alias migration
retains the original client input identity and receipt lookup.

## Migration

The host imports its old receipt and plan JSON files, and the Pi, Copilot, and
ACPx sidecars. The client imports old transcript, recent-session, favorite, and
outbox preferences. Each import commits data and its migration marker together.
A failed import leaves its source available for retry. Original sources remain
available for comparison; normal operation no longer writes the old sidecars.

Stable instance aliases prevent a default-provider change from transferring an
old session to another provider. A conflicting ownership map fails the migration.
The client combines favorite flags, keeps the newest valid cache, and preserves
pending input identities when it adopts canonical session IDs.

## Checks

The server store, coordinator, input, and history tests cover rollback, reopen,
uncertain sends, queued shutdown, delayed native persistence, and incomplete
snapshots. Optional native checks use isolated agent homes and send no model
prompt. See [runtime compatibility](dependency-runtime-compatibility.md).

The client storage tests cover schema upgrades, original-source retention,
rollback, identity migration, database reopen, and outbox capacity. They run with
native SQLite on desktop. `bash scripts/test-flutter-web-storage.sh` runs the same
tests in Chrome with the shipped SQLite worker and IndexedDB backend. CI also
runs the native storage and provider-control checks on Windows and macOS.

Provider controls are checked in both existing display modes. These tests do not
certify every release of a third-party agent or replace device checks for native
platform plugins.
