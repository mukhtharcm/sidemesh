# Sidemesh Backlog

This is the near-term provider backlog for keeping Codex strong while bringing
GitHub Copilot and future coding agents behind the same Sidemesh API.

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
- [x] Add provider-capability plumbing so the daemon and app can prepare for non-Codex adapters.
- [x] Add a provider registry, provider factory, and documented adapter contract.
- [x] Add a deterministic fake provider for capability/profile testing.
- [x] Add a GitHub Copilot provider backed by the Copilot SDK for sessions,
      transcript replay, model metadata, image input, skills, permissions, and
      interactive prompts.
- [x] Add multi-provider daemon support so one node can expose more than one
      provider.
- [x] Gate create-session, runtime controls, attachments, approvals, file
      browsing, and skills by provider and host capabilities.
- [x] Add provider switching in the new-session flow for mixed-provider hosts.
- [x] Surface provider identity in host details, recent sessions, and session
      headers.
- [x] Add setup/doctor/status/pair CLI flows for local daemon onboarding.

## Current Wave

- [ ] Add a provider-neutral integrated terminal: opt-in host capability,
      PTY-backed live shell, reconnect replay, mobile key row, and later tmux
      durability when available.
- [ ] Bring Copilot provider UX up to Codex parity where the SDK supports it.
- [ ] Harden provider-neutral approvals across command, tool, file-change,
      user-input, and elicitation requests.
- [ ] Make multi-provider hosts easier to scan and operate: provider filters,
      provider-aware session creation, and clearer mixed-provider health states.
- [ ] Harden reconnect/background resume so approvals and final answers never
      disappear after a socket drop.
- [ ] Improve active-run steering and queued follow-ups across providers.
- [ ] Keep Codex-specific compatibility shims documented and easy to remove.

## Next Up

- [ ] Add provider-aware filters/grouping in `Recent`, `Hosts`, and `Inbox`.
- [ ] Expand the fake provider scenario harness so one automated flow can cover
      chat, images, tools, approvals, files, skills, and reconnect replay.
- [ ] Add provider-neutral settings for provider defaults where possible, and
      hide provider-private controls unless the provider advertises them.
- [ ] Fully support `item/permissions/requestApproval`, including partial grants and turn vs session scope.
- [ ] Show richer approval detail: requested permissions, cwd, reason, and available decisions.
- [ ] Add session fork via `thread/fork`.
- [ ] Add rollback and manual compaction via `thread/rollback` and `thread/compact/start`.
- [ ] Add review flows via `review/start` for uncommitted changes, branch diff, and commit review.
- [ ] Add queue and steering UX for follow-ups while a run is active.

## Codex Control Surface

- [ ] Show account/auth state from `account/read`.
- [ ] Show model choices from `model/list`.
- [ ] Add a temporary Codex resume compatibility shim that restores persisted `modelProvider` for unloaded sessions, then remove it once Codex app-server natively restores provider/profile state on `thread/resume`.
- [ ] Track `ollama-launch` `/v1/responses` flakiness separately from Sidemesh resume bugs; simple `ollama run` can work while multi-step Codex Responses payloads intermittently fail upstream with `502`/TLS transport errors.
- [ ] Add activity cards for review mode and reconnecting.
- [ ] Add activity cards for plan updates, reasoning summaries, web search, MCP calls, and context compaction.
- [ ] Surface model reroutes and token usage updates while a turn is running.
- [ ] Add quick shell utilities with `thread/shellCommand` or `command/exec`.
- [ ] Add Git context cards on the host and session screens.
- [ ] Move provider-leaky workspace intelligence host-side where possible,
      starting with remote git diff so every provider gets the same git UI.

## Security And Onboarding

- [ ] Replace manual URL/token entry with pairing.
- [ ] Add host revocation and token rotation.
- [ ] Investigate device enrollment using Codex device-key APIs instead of static bearer tokens.

## Ops And Handoff

- [ ] Document a VPS-first maintainer workflow so Sidemesh can be updated and operated even when the primary Mac is offline.
- [ ] Write a lightweight server release playbook for remote nodes: pull latest `main`, restart the daemon/service, and verify Codex + Sidemesh health.
- [ ] Bring the production launcher and deploy scaffolding into the repo so remote updates cannot delete `run-sidemesh.sh` and break `systemd`.

## Later

- [ ] Expose Codex apps and plugins through `app/list` and related APIs.
- [ ] Surface MCP server status and selected MCP tools.
- [ ] Investigate whether Copilot exposes more granular permission controls than
      the current SDK-backed adapter reports.
- [ ] Investigate OpenClaw Gateway as a provider.
- [ ] Add more real providers only after the provider contract and fake harness
      stay stable across Codex and Copilot.
