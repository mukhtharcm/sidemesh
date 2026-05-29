# AGENTS.md — Sidemesh Agent Instructions

> **Meta**: Update this file when you learn a codebase quirk that would help
> future tasks.

## Critical Rules

- **MANDATORY**: Run `npm run typecheck` after any TypeScript change and fix all
  errors before running tests or declaring work complete.
- **MANDATORY**: Run `flutter analyze` in `apps/mobile/` after any Dart/Flutter change and fix all errors before declaring work complete.
- **NEVER** run tests if `npm run typecheck` fails.
- **NEVER** commit tokens, private hostnames, generated env files, signing
  profiles, certificates, or app-store keys.
- **NEVER** create git worktrees inside the repo (e.g. under `.worktrees/` or
  `worktrees/` inside the repo root). Always create them outside the repo,
  e.g. `../worktrees/<branch-name>`. Stale nested worktrees pollute the repo
  and complicate cleanup.
- **NEVER** restart the Sidemesh daemon (`systemctl restart sidemesh`, `kill`,
  etc.) from a session running *inside* that same daemon. systemd kills the
  entire cgroup including your own process tree. Use an out-of-band mechanism
  (see "Resilient Daemon Updates" below).
  public-internet exposure features without a proper auth layer.
- Terminal, filesystem, and approval changes are **high-trust surfaces**;
  keep them conservative and well-tested.

## Project Overview

Sidemesh is a fleet-first mobile control plane for agent sessions.

- **Node daemon** (`src/`): exposes local agent providers (Codex, Copilot CLI,
  fake test provider) over a WebSocket + HTTP API.
- **Flutter client** (`apps/mobile/`): multi-host mobile/desktop app for chat,
  approvals, session policy, workspace files, and live activity.
- **Web landing** (`web/`): static site deployed via Cloudflare Pages.

The daemon and client communicate through a **capability-based contract** so
new providers can be added without client changes.

## Repo Shape

```
src/
  agent-provider.ts          # Core provider interface — READ THIS FIRST for adapter work
  types.ts                     # Shared daemon types and provider configs
  provider-registry.ts         # Provider metadata + factory definitions
  provider-factory.ts          # Provider construction
  multi-provider.ts            # Multi-provider facade with namespaced IDs
  codex-provider.ts            # Codex adapter
  copilot-provider.ts          # Copilot CLI adapter
  fake-provider.ts             # Deterministic test harness
  server.ts                    # Express HTTP + WebSocket server
  fs-routes.ts                 # Host filesystem API
  terminal.ts                  # Host integrated terminal
  browser-preview.ts           # Host browser tabs
  approvals.ts                 # Approval model normalization
  config.ts / config-store.ts  # Config loading and persistence
  cli.ts                       # CLI entry point
  daemon-lifecycle.ts          # Daemon PID/state management
  git.ts                       # Git operations
  workspace-scope.ts           # Workspace path resolution / sandboxing
  session-input-dedupe-store.ts  # On-disk input deduplication ledger
  session-replay-index.ts      # Incremental .jsonl parser for Codex rollouts
apps/mobile/lib/src/
  screens/                     # Flutter screens
  theme/                       # App theming
  widgets/                     # Reusable widgets
  *Store.dart                  # Data/cache classes
  *Controller.dart             # UI state classes (ChangeNotifier)
```

- `*.test.ts` files live **alongside** the module they test in `src/`.
- Flutter tests live in `apps/mobile/test/`.
- No barrel re-exports; import from the owning file directly.

## Tech Stack

| Layer | Runtime / Language | Key Tools |
|-------|------------------|-----------|
| Daemon | Node.js 20+, TypeScript 6.x | `tsx`, `tsc`, `node:test` |
| Client | Flutter 3.41.7 (stable), Dart | `flutter test`, `flutter analyze` |
| Web | Vanilla HTML/JS | Cloudflare Pages |

TypeScript: `strict`, ES2022, `NodeNext` module resolution. **No linter or
formatter** — follow file-local conventions.

## Default Development Loop

### Server (TypeScript)

Fast iteration (single file):

```bash
node --import tsx --test src/some-module.test.ts
```

Before finishing any server change:

```bash
npm run typecheck      # MANDATORY first
npm run test:server    # all server tests
npm run build          # compile to dist/
```

### Flutter

```bash
cd apps/mobile
flutter pub get
flutter test test/provider_metadata_models_test.dart
flutter test test/api_client_provider_scoping_test.dart
flutter test test/capability_ui_gates_test.dart
flutter analyze
```

### Pre-merge Gates

```bash
# Server
npm run typecheck && npm run test:server && npm run build && npm pack --dry-run

# Flutter
cd apps/mobile && flutter test && flutter analyze
```

## Architecture

### Provider Adapter Contract

Every provider implements the interface in `src/agent-provider.ts`.

- **Required**: `kind`, `displayName`, `capabilities`, `start()`, `getVersion()`.
- **Optional methods** must match advertised `AgentProviderCapabilities`.
- The Flutter app **gates UI on capability flags**; never add UI that depends on
  a capability not declared in the contract.
- Register a new provider by adding a full `*_PROVIDER_DEFINITION` to the
  `AGENT_PROVIDER_DEFINITIONS` array in `src/provider-registry.ts`.
  Implement `expect*ProviderConfig` guards; the registry throws for unknown
  kinds at runtime.
- `setupAudience: "public" | "dev"` controls which providers appear in
  `sidemesh setup`. The fake provider is dev-only.

### Multi-Provider Mode

- When `config.providers.length > 1`, `provider-factory.ts` wraps them in
  `MultiAgentProvider` automatically.
- IDs are namespaced: `kind:base64url(rawId)`.
- `MultiAgentProvider.capabilities` reflects the default provider only; use
  `supportedProviders[].capabilities` from `/api/node` for per-provider truth.
- `stderr` gets a `[kind] ` prefix for non-default providers.
- If the resolved provider lacks a capability, the call throws even if another
  provider has it.

### Host vs. Provider Responsibilities

| Feature | Owner | Key File(s) |
|---------|-------|-------------|
| Session history, input, interrupts | Provider | `src/codex-provider.ts`, `src/copilot-provider.ts` |
| Approvals / pending actions | Provider (host renders UI) | `src/approvals.ts`, `src/agent-provider.ts` |
| Model/profile/skill lists | Provider | Provider adapter files |
| Local filesystem browse/read/write | Host | `src/fs-routes.ts` |
| Local git status / working diff | Host | `src/git.ts` |
| Integrated terminal | Host | `src/terminal.ts` |
| Browser tabs | Host | `src/browser-preview.ts` |

**Rule of thumb**: default to **host-owned** unless it fundamentally requires a
specific agent provider.

## Code Conventions

### TypeScript / Node.js

- Use `node:` prefixes for built-ins.
- Prefer `node:fs/promises` async APIs; sync only for startup/CLI paths.
- Use explicit `import type { Foo } from "./bar.js"` for type-only imports.
- **Include `.js` extensions in all relative imports** — required by `NodeNext`.
- Prefer `unknown` over `any`.
- Use `as const` for readonly literals, `private readonly` for immutable fields.
- Use `Map<string, T>` for in-memory keyed state.
- Providers extend `EventEmitter` and emit `liveEvent`, `stderr`, `exit`.
- Use Zod for runtime validation; schemas live near the types they validate
  (see `src/config-store.ts`).
- Keep provider-specific protocol translation **inside the adapter file**.
  Do not leak Codex-specific shapes into `src/types.ts` unless the abstraction
  cannot express the concept.

### Tests (Node.js)

- Use `node:test` (`describe`, `it`) and `node:assert/strict`. No external runner.
- Name test files `*.test.ts` alongside the module they test.
- Tests run from source via `tsx` — **no build step required**.

### Flutter / Dart

- Use `import 'package:…'` for deps, `import 'src/…'` for internal modules.
- Prefer `final` over `var`; use `const` where possible.
- Screens go in `apps/mobile/lib/src/screens/`.
- State patterns:
  - `*Store` classes for data/cache (may extend `ChangeNotifier`).
  - `*Controller` classes for UI state (extends `ChangeNotifier`).
  - `InheritedNotifier` / `InheritedWidget` for scoped DI
    (see `theme_controller.dart`).
- Defensive JSON parsing: on exception, remove the offending key and return a
  default (see `session_cache_store.dart`).

## Specific Gotchas

- **Duplicate daemon guard**: `sidemesh start` checks `healthz` and refuses to
  start if occupied. Use `--allow-duplicate` to skip.
- **Config persistence**: `sidemesh setup` writes to `~/.sidemesh/config.json`
  (or `SIDEMESH_CONFIG`). Atomic write-then-rename with `0o600` permissions.
  The daemon reads from `SIDEMESH_STATE_DIR` (defaults to `~/.sidemesh`).
  Runtime `NodeConfig.port` may be `0` in tests or ephemeral dev servers;
  persisted config only allows `1-65535`, so serialization must omit `0`
  instead of writing it back to disk.
- **macOS unsandboxed**: The macOS build runs unsandboxed by design so keychain
  access works without extra signing. `file_picker` 11+ assumes sandboxed apps
  and performs an entitlement check — we explicitly skip it in `main.dart`.
- **macOS path_provider FFI**: `path_provider_foundation` now uses the
  `objective_c` native asset on macOS. If that framework is missing from a
  debug app bundle, early calls like `getApplicationSupportDirectory()` can
  crash at runtime. Prefer direct `~/Library/.../<bundle-id>` resolution for
  startup-critical local storage paths in this app.
- **Flutter flavors**: Build/run commands must include `--flavor dev` or
  `--flavor prod`.
- **No formatter**: No Prettier, Biome, or ESLint. Follow file-local style.
- **WebSocket `hello`**: The server sends `{"type":"hello"}` on every WS
  connection.
- **Session replay freshness**: live activity updates must not be replay-filtered
  only by the activity's original `seq`. Activities keep their transcript order
  stable while replay freshness is tracked separately in `src/server.ts`, so
  delta sync should use the replay cursor rather than assuming updated
  activities get a newer transcript `seq`.
- **Mobile delta parity**: `SessionEventsDelta` does not include a full
  `history` summary. When replaying deltas into a cached session,
  `apps/mobile/lib/src/screens/session_screen.dart` must keep
  `SessionLogHistorySummary` in sync locally or the “older history” UI can stay
  stale until a full snapshot reload.
- **Delta staleness fallback**: some providers can expose newer session state
  without any replayable `seq` bump (for example, persisted activity details
  changing in place). `GET /api/sessions/:id/events` can therefore return a
  `stale_snapshot` error when the caller's `baseUpdatedAt` is older than the
  current session `updatedAt` but there are no replayable message/activity/plan
  deltas. Mobile session refresh paths should treat that as a signal to reload
  the full snapshot automatically.
- **Cached session verification**: delta replay is a fast first pass, not a
  proof that a cached or resume-stale transcript is fully fresh. When the
  session screen is showing cached or possibly stale content, it should still
  verify with a full snapshot after delta replay before clearing stale-state UI.
  Provider `updatedAt` values can be coarse, and transcript rows can mutate in
  place without producing replayable deltas.
- **Workspace sandboxing**: `resolveWorkspacePath` uses `realpath` and prefix
  match against workspace roots. `WorkspaceAccessError` extends `Error` with
  a `status` field (default 403) that HTTP handlers can throw directly.
- **Terminal security**: `SIDEMESH_TOKEN` is deleted from env before spawning
  the shell; `SIDEMESH_TERMINAL_SESSION=1` is injected.
- **Termux / Android PTY support**: keep `node-pty` optional. Do not
  reintroduce eager top-level PTY imports or make `node-pty` a required npm
  dependency; Termux installs can lack a working native addon, so the daemon
  must still start and fall back to `script`/pipe-backed terminals.
- **Termux services**: native managed service support uses `termux-services`
  (`runit`) via `src/termux-service.ts`, not `systemd`. Termux service files
  live under `$PREFIX/var/service/<name>` and use `$PREFIX/var/log/sv/<name>`
  for logs; preserve this layout so `sv`, `sv-enable`, and Termux:Boot work.
- **Port forwarding lockdown**: Targets must resolve to loopback by default.
  Enable `allowNonLoopbackTargets` in config to relax.

## Common Workflows

### Running the Daemon Locally

```bash
npm install
npm run setup        # writes ~/.sidemesh/config.json
npm run daemon       # foreground dev server via tsx
```

Compiled CLI:

```bash
npm run build
npm link
sidemesh setup
sidemesh start       # background daemon
sidemesh pair        # show host URL + token for mobile app
```

### Adding a New Provider

1. Add the provider kind to `AgentProviderKind` in `src/types.ts`.
2. Add config type to `AgentProviderConfig` in `src/types.ts`.
3. Implement the adapter in `src/<name>-provider.ts`.
4. Add a `*_PROVIDER_DEFINITION` to `AGENT_PROVIDER_DEFINITIONS` in
   `src/provider-registry.ts` and register construction in
   `src/provider-factory.ts`.
5. Add focused tests using `src/fake-provider.ts` patterns.
6. Update `CONTRIBUTING.md` and this file if the contract changes.

### Release Artifacts

Do not publish npm, app-store, TestFlight, or GitHub release artifacts without
following `docs/release-playbook.md`.

macOS app updates are Sparkle-based and separate from daemon self-updates. The
appcast is published as a GitHub Release asset on `macos-appcast-prod`, while
the update ZIP stays on the versioned macOS app release. The daemon probing UI
still only updates connected host daemons.

iOS and macOS app release workflows use the committed `apps/mobile/pubspec.yaml`
version only. Bump it with `npm run mobile:version -- X.Y.Z+N`; do not rely on
workflow inputs or git tags to change app version/build numbers. macOS app
release tags use `macos-vX.Y.Z+N`; npm package release tags use
`npm-v<package.json version>`. TestFlight and Sparkle appcast publishing both
perform remote monotonic-version checks before uploading release artifacts.

### Resilient Daemon Updates

Because systemd kills the entire cgroup on restart, **do not** restart the
daemon from a shell or tool spawned by the daemon itself. Instead:

1. Build into `/opt/sidemesh/dist` from the repo (safe).
2. Trigger a deferred restart outside the cgroup:
   ```bash
   # Runs after the current shell exits
   (sleep 5 && systemctl restart sidemesh) & disown
   ```
3. Or install a systemd path/timer unit that watches `dist/cli.js` mtime and
   restarts automatically when the binary changes.

Until such a unit exists, the human operator must run the restart manually from
a separate SSH session after confirming the build succeeded.

## Quick References

- Provider contract: `docs/provider-adapter-contract.md`
- Contributing guide: `CONTRIBUTING.md`
- Release playbook: `docs/release-playbook.md`
- CI definition: `.github/workflows/ci.yml`
