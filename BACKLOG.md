# Sidemesh Backlog

This is the near-term Codex-only backlog for bringing the mobile client closer to full `codex app-server` parity.

## Recently Completed

- [x] Make `Recent` the default landing page.
- [x] Move host management into a dedicated `Hosts` page.
- [x] Add a global `Inbox` page for pending approvals across hosts.
- [x] Add badges for pending approvals and active sessions in the tab bar.
- [x] Add rich markdown rendering for assistant output.
- [x] Add selectable inline code, selectable code blocks, and copy buttons for assistant output.
- [x] Add session rename via `thread/name/set`.
- [x] Add archive and unarchive via `thread/archive` and `thread/unarchive`.
- [x] Expose per-session runtime settings such as model, sandbox mode, approval policy, and network access.
- [x] Add typed activity cards for command execution, file edits, terminal stdin, and turn-level diff cards.
- [x] Add a workspace file browser/editor backed by Codex `fs/*`, including live `fs/watch` updates.
- [x] Link file paths from assistant output and activity cards into the workspace file viewer.
- [x] Add resilient chat streaming with seq-aware reconnects and a cheap delta replay endpoint.
- [x] Add per-device unread indicators, favorites, host reachability, and background approval polling.
- [x] Move host tokens from `SharedPreferences` to platform secure storage.

## Current Wave

- [ ] Tighten full approval parity.
- [ ] Add first-class model/account discovery.
- [ ] Add advanced thread lifecycle controls.
- [ ] Improve active-run steering and queued follow-ups.

## Next Up

- [ ] Fully support `item/permissions/requestApproval`, including partial grants and turn vs session scope.
- [ ] Show richer approval detail: requested permissions, cwd, reason, and available decisions.
- [ ] Add session fork via `thread/fork`.
- [ ] Add rollback and manual compaction via `thread/rollback` and `thread/compact/start`.
- [ ] Add review flows via `review/start` for uncommitted changes, branch diff, and commit review.
- [ ] Add queue and steering UX for follow-ups while a run is active.

## Codex Control Surface

- [ ] Show account/auth state from `account/read`.
- [ ] Show model choices from `model/list`.
- [ ] Add activity cards for review mode and reconnecting.
- [ ] Add activity cards for plan updates, reasoning summaries, web search, MCP calls, and context compaction.
- [ ] Surface model reroutes and token usage updates while a turn is running.
- [ ] Add quick shell utilities with `thread/shellCommand` or `command/exec`.
- [ ] Add Git context cards on the host and session screens.

## Security And Onboarding

- [ ] Replace manual URL/token entry with pairing.
- [ ] Add host revocation and token rotation.
- [ ] Investigate device enrollment using Codex device-key APIs instead of static bearer tokens.

## Later

- [ ] Expose Codex apps and plugins through `app/list` and related APIs.
- [ ] Surface MCP server status and selected MCP tools.
- [ ] Add a provider abstraction for non-Codex backends once Codex parity is strong enough.
- [ ] Investigate GitHub Copilot local sessions via the Copilot SDK.
- [ ] Investigate OpenClaw Gateway as a provider.
- [ ] Revisit multi-agent support once Codex parity is strong enough.
