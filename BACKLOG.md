# Sidemesh Backlog

This is the near-term Codex-only backlog for bringing the mobile client closer to full `codex app-server` parity.

## Current Wave

- [x] Make `Recent` the default landing page.
- [x] Move host management into a dedicated `Hosts` page.
- [x] Add a global `Inbox` page for pending approvals across hosts.
- [x] Add basic markdown rendering for assistant output.

## Next Up

- [ ] Fully support `item/permissions/requestApproval`, including partial grants and turn vs session scope.
- [ ] Show richer approval detail: requested permissions, cwd, reason, and available decisions.
- [ ] Add badges for pending approvals and active sessions in the tab bar.
- [ ] Add session rename via `thread/name/set`.
- [ ] Add session fork via `thread/fork`.
- [ ] Add archive and unarchive via `thread/archive` and `thread/unarchive`.
- [ ] Add rollback and manual compaction via `thread/rollback` and `thread/compact/start`.
- [ ] Add review flows via `review/start` for uncommitted changes, branch diff, and commit review.
- [ ] Add queue and steering UX for follow-ups while a run is active.

## Codex Control Surface

- [ ] Show account/auth state from `account/read`.
- [ ] Show model choices from `model/list`.
- [x] Expose per-session runtime settings such as model, sandbox mode, and approval policy.
- [x] Add typed activity cards for command execution and file edits.
- [x] Show live command action summaries, terminal stdin, and turn-level diff cards.
- [ ] Add activity cards for review mode and reconnecting.
- [ ] Add activity cards for plan updates, reasoning summaries, web search, MCP calls, and context compaction.
- [ ] Surface model reroutes and token usage updates while a turn is running.
- [ ] Add a lightweight file browser using `fs/readDirectory`, `fs/readFile`, and `fs/getMetadata`.
- [ ] Add quick shell utilities with `thread/shellCommand` or `command/exec`.
- [ ] Add Git context cards on the host and session screens.

## Security And Onboarding

- [ ] Move host tokens from `SharedPreferences` to secure storage.
- [ ] Replace manual URL/token entry with pairing.
- [ ] Add host revocation and token rotation.
- [ ] Investigate device enrollment using Codex device-key APIs instead of static bearer tokens.

## Later

- [ ] Expose Codex apps and plugins through `app/list` and related APIs.
- [ ] Surface MCP server status and selected MCP tools.
- [ ] Revisit multi-agent support once Codex parity is strong enough.
