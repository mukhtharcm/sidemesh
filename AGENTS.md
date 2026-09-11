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
  session-identity.ts          # Stable instance ownership and legacy session aliases
  codex-provider.ts            # Codex adapter
  copilot-provider.ts          # Copilot CLI adapter
  fake-provider.ts             # Deterministic test harness
  server.ts                    # Hono HTTP + WebSocket server
  fs-routes.ts                 # Host filesystem API
  terminal.ts                  # Host integrated terminal
  browser-preview.ts           # Host browser tabs
  approvals.ts                 # Approval model normalization
  config.ts / config-store.ts  # Config loading and persistence
  cli.ts                       # CLI entry point
  daemon-lifecycle.ts          # Daemon PID/state management
  git.ts                       # Git operations
  workspace-scope.ts           # Workspace path resolution / sandboxing
  session-store.ts             # Durable SQLite input records and saved plans
  session-coordinator.ts       # Published session view, native snapshots, durable input queue
  state-writer.ts              # Coalesced durable snapshot writes
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
| Daemon | Node.js 22.19+, TypeScript 6.x | `tsx`, `tsc`, `node:test` |
| Client | Flutter 3.44.7 (stable), Dart 3.12 | `flutter test`, `flutter analyze` |
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

### Configured Provider Instances

- `AgentProviderRuntime` holds a direct map of configured instances. It is not
  an `AgentProvider`. Resolve an instance and its native session ID before a call.
  Construction and startup are lazy. Host health and controls remain available
  when a provider fails. `/api/node` and `/api/providers` report each instance's
  state, error, and version; restart recreates only that instance.
- Configured providers have stable `id` values. Old entries default to their kind.
  Keep the old entry ID when adding another instance of that kind. Set
  `defaultProviderId` to select an instance. IDs are namespaced as
  `instanceId:base64url(rawId)`, including single-provider hosts. SQLite pins
  legacy raw IDs and kind aliases to their original owner. A default change or
  provider removal must never transfer that ownership. Reusing an instance ID
  for another kind or a saved alias fails closed.
- Inputs, plans, recovery, and locks use canonical IDs. Old HTTP and WebSocket
  callers receive their requested session alias. Input alias conflicts abort
  the migration transaction and preserve both original delivery records.
- Use `supportedProviders[].capabilities` from `/api/node` for instance truth.
- `stderr` gets an `[instanceId] ` prefix.
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

- **ACP integration**: use `src/acp-provider.ts` and the official ACP SDK.
  The stored kind remains `acpx` for compatibility; the ACPx runtime is removed.
  Keep exact permission option IDs. Boolean configuration requests need
  `type: "boolean"`; the SDK's generic request overload can otherwise hide a
  bad payload behind an `unknown` return type. A completed `session/load` ends
  a staged replay; `session/resume` does not replay history. ACP display data
  and local metadata use the host's `sessions-v1.db`. Preserve old JSON files
  during the transactional import. Cold session lists and archive operations
  must not launch the agent.

- **Theme ownership**: run `python3 scripts/check_flutter_theme.py` before
  Flutter tests. Use `lib/src/theme/` for tokens and component style recipes.
  Do not restore local numeric typography, colors, padding, radii, button or
  input recipes in screens. Message and status colors live in
  `theme/message_text_styles.dart` and `theme/app_status_styles.dart`.
  Transparent ownership surfaces, responsive layout constraints, and protocol
  timings are not visual theme overrides.
  Use `Switch` for app-owned controls: `Switch.adaptive` can bypass the
  shared switch colors on Apple platforms. Keep `AppSettingsRow` controls
  as siblings; a row inside another row's footer adds a second text inset.

- **Trailing Flutter menus**: fixed-width action menus must set
  `crossAxisUnconstrained: false` on `MenuAnchor`. Otherwise the visible panel
  can shrink while its position still uses the fixed width, leaving a gap
  beside the trigger. Check the visible panel with real fonts as well as tests.

- **Duplicate daemon guard**: `sidemesh start` checks `healthz` and refuses to
  start if occupied. Use `--allow-duplicate` to skip.
- **Durable session state**: `sessions-v1.db` holds host input records and saved
  plans. It imports the old input ledger and runtime signals transactionally;
  keep the original JSON files. An input in `dispatching` becomes `uncertain`
  after restart. Never resend it automatically or prune its recovery payload.
- **Config persistence**: `sidemesh setup` writes to `~/.sidemesh/config.json`
  (or `SIDEMESH_CONFIG`). Atomic write-then-rename with `0o600` permissions.
  The daemon reads from `SIDEMESH_STATE_DIR` (defaults to `~/.sidemesh`).
  Runtime `NodeConfig.port` may be `0` in tests or ephemeral dev servers;
  persisted config only allows `1-65535`, so serialization must omit `0`
  instead of writing it back to disk.
- **macOS launch callback**: `FlutterAppDelegate` can leave optional
  `NSApplicationDelegate` callbacks unimplemented. Before calling
  `super.applicationDidFinishLaunching`, check `instancesRespond(to:)` or
  the launch can raise an unrecognized-selector exception on newer Flutter.
- **macOS unsandboxed**: The macOS build runs unsandboxed by design.
  `file_picker` 11+ assumes sandboxed apps
  and performs an entitlement check — we explicitly skip it in `main.dart`.
- **macOS keychain**: Signed releases require a Developer ID provisioning
  profile and use the Data Protection Keychain. Packaging validates and embeds
  the profile before signing with its authorized entitlements. The fresh host
  list requires re-pairing once; never read or clean up legacy keychain items
  in this path, as either operation can show password prompts. Ad-hoc dev
  builds retain the regular keychain. See `docs/release-playbook.md`.
- **macOS path_provider FFI**: `path_provider_foundation` now uses the
  `objective_c` native asset on macOS. If that framework is missing from a
  debug app bundle, early calls like `getApplicationSupportDirectory()` can
  crash at runtime. Prefer direct `~/Library/.../<bundle-id>` resolution for
  startup-critical local storage paths in this app.
- **Platform density tests**: theme construction selects desktop or touch control
  sizes from the active platform. Use `TargetPlatformVariant` in widget tests;
  changing only `ThemeData.platform` after construction does not rebuild the
  input and button themes.
- **Speedflight requests**: Treat “deploy to Speedflight”, “send a Speedflight
  build”, or “share an iOS build with Speedflight” as a request to build and
  upload, then return the install page link. Follow “Local iOS Sharing with
  Speedflight” in `docs/release-playbook.md`, including its preflight checks.
  Reuse the existing `.env.speedflight` and local export settings; do not
  replace the upload secret. These files are local to a checkout. If absent,
  check other worktrees of this repository for the existing setup before
  asking for credentials. Never print or commit their contents.
  Commit and push the intended source on a feature branch, write a short
  build title and test notes, then run `scripts/speedflight.sh "<title>" "<notes>"`.
  Return the script's app page link privately in the chat with the version and
  build number. Do not post the install link in a public PR or CI log.
- **Speedflight**: `scripts/speedflight.sh` builds the prod iOS workspace for
  ad hoc distribution. Local `.env.speedflight` holds signing settings and the
  upload secret; keep it out of Git. `FLUTTER_BIN` can select the Flutter SDK
  used by CI. The script overrides manual App Store signing for both the app
  and Live Activity extension, without editing the project signing settings.
  Cloud signing access can fail even when the API key can manage profiles.
  `SPEEDFLIGHT_EXPORT_OPTIONS_PLIST` supports export with an existing local
  distribution certificate and ad hoc profiles provisioned through `asc`.
  A locked keychain ahead of the login keychain can shadow the same signing
  identity and cause `errSecInternalComponent`; check keychain search order
  before replacing certificates or changing Apple account permissions.
- **Flutter flavors**: Build/run commands must include `--flavor dev` or
  `--flavor prod`.
- **Flutter control geometry**: shared button themes set platform-specific
  minimum heights and `VisualDensity.standard`. Flutter's desktop density
  otherwise reduces the painted button below that minimum. For a text field
  inside an existing border, use `AppInputDecorations.borderless`; setting only
  `border: InputBorder.none` leaves inherited enabled/focused borders active.
- **TestFlight resume**: If App Store Connect accepts the IPA but a later
  metadata or internal-distribution step fails, rerun `Deploy to TestFlight`
  with `resume_existing_build` enabled. It resolves the exact committed
  pubspec version/build without rebuilding or uploading a duplicate binary.
  Internal groups whose `hasAccessToAllBuilds` flag is true already receive the
  build and must not be passed to the manual group-assignment API.
- **Flutter web**: The browser entry point is `apps/mobile/lib/main_web.dart`.
  Build it with `npm run mobile:web:build`; the hosted client only accepts
  remote daemon URLs over HTTPS/WSS. Browser WebSocket authentication uses the
  `sidemesh.auth.<base64url-token>` subprotocol, while the server selects only
  the non-secret `sidemesh` protocol in its response.
- **Client storage checks**: `bash scripts/test-flutter-web-storage.sh` runs the
  existing migration and outbox tests in Chrome with the real SQLite worker.
  It temporarily copies web runtime assets into the test server root and removes
  them on exit. `FLUTTER_BIN` selects the pinned SDK. Do not commit those copies.
- **Flutter web SQLite**: `apps/mobile/web/sqlite3.wasm` and
  `apps/mobile/web/sqflite_sw.js` are generated runtime assets. Regenerate them
  from `apps/mobile/` with
  `dart run sqflite_common_ffi_web:setup --force` after upgrading the package.
- **No formatter**: No Prettier, Biome, or ESLint. Follow file-local style.
- **Pi RPC**: execution uses the official `rpc-entry` process. Use
  `agent_settled` for completion; `agent_end` can precede automatic retries.
  `get_entries` follows `leafId`, and its entries can precede native disk writes.
  Confirm durable history against the native file before removing recovery
  records. Use `parseSessionEntries` with a read-only file read;
  `SessionManager.open` repairs partial files and must not be used for reads.
  Load the public SDK only for file discovery/history and catalogs.
  Extension UI requests can occur during startup; session reads must not wait
  for startup questions to finish. Never use private SDK event queues.
- **Codex history messages**: newer rollouts use `event_msg.item_completed`
  with `UserMessage` / `AgentMessage` items instead of `user_message` /
  `agent_message` events. Read both formats for transcripts and previews.
  Do not also promote `response_item.message`: it includes model context and
  copies of visible messages.
  Transcript reads use app-server `thread/read`; retain the documented legacy
  tool-output and runtime-settings supplements until upstream closes those
  gaps. Codex `0.144.6` cannot read paginated histories. Native paginated test
  fixtures on `0.154.0` need JSONL ordinals and native resume to build their
  native projection. Never write that database directly.
- **Copilot SDK types**: derive adapter method types from the installed SDK.
  SDK 1.0.4 exposes history through `session.getEvents()` and manual compaction
  through `session.rpc.history.compact()`. The wire method `session.getMessages`
  is not a JavaScript method. Do not cast a client through `unknown` to a copied
  interface; this hides missing methods in production while mocks still pass.
  Refresh `getEvents()` for full snapshots. Keep native IDs from `send()` and
  recovery content in the shared session database; `sessions.json` is only an
  import source. Use `metadata.activity()` and `session.idle` for execution
  state. `assistant.turn_end` ends a loop iteration, and child errors must not
  complete the parent turn.
- **OpenCode SDK events**: use the official SDK and subscribe before reading
  session state. A completed assistant message can be followed by more tools;
  only native idle ends the turn. Reconnect invalidates loaded history and
  refreshes pending requests. Keep prompt recovery until native history
  confirms it. `stateDir` controls native XDG paths; host recovery uses the
  shared session database. Never log the owned server's temporary password.
- **WebSocket `hello`**: The server sends `{"type":"hello"}` on every WS
  connection.
- **Session freshness**: recover through `GET /api/sessions/:id/log` on open,
  every WebSocket `hello`, app resume, and turn completion. There is no events
  replay endpoint. `seq` orders transcript items; it does not prove freshness.
  Snapshot/live `revision` identifies events covered by the latest snapshot,
  including delayed WebSocket deliveries after the HTTP response. It resets
  with the daemon and must never skip a reconnect refresh.
- **Input delivery**: `SessionInputCoordinator` owns input serialization and
  the SQLite queue. Set `capabilities.input.steer = false` when an adapter
  cannot accept input during a turn. A `queued` receipt means the host saved
  the payload; it does not mean execution started. Native acceptance is also
  not proof of durable completion. Keep unconfirmed payloads and block retries
  with an uncertain delivery result. Only set `inputNotDispatched` on a provider
  error when the prompt was never sent. Stop/archive cancel queued rows before
  interruption, and shutdown retains queued rows without starting new work.
- **Image-bearing tool results**: expose screenshots and other returned images
  through provider-neutral `ToolActivity.attachments`, not fabricated assistant
  messages. Shared normalization recognizes common OpenAI, MCP, and ACP content
  blocks and strips promoted inline image data from the raw result.
- **Spawned agent sessions**: child sessions are not peer rows in Recent or
  session search. Discover them through the parent-scoped agent-runs path.
  Provider adapters must filter before applying the requested limit, and
  provider runtime routing must namespace `subAgent.parentSessionId` as well as
  the child thread id.
- **Provider snapshots and input proof**: `readSessionSnapshot` returns native
  history, runtime, thread data, busy state, and available turn identity after
  all upstream reads. A busy agent can have no public turn ID. Input receipts
  become confirmed only through explicit native identity or a completed protocol
  operation; matching display IDs or repeated prompt text is not proof. Pi needs
  an observed native timestamp and matching content in its durable entry file.
- **Search summaries**: the disposable search database stores full session summaries
  and provider instance IDs. Search results must not start native reads for each
  result. Index from the coordinator snapshot; compare actual searchable content
  and summary data, since existing messages can change without a new sequence or
  timestamp. Apply configured provider IDs before the search result limit.
- **Host session coordinator**: log, status, resource, and input-dispatch reads use
  one complete `readSessionSnapshot`. An input receipt does not start a turn.
  `busy` can be true without a native turn ID; providers own cancellation in
  that case. Initial input uses the same durable queue as later input. The
  coordinator stores unconfirmed messages, drafts, and tool updates in SQLite
  `session_recovery`; native history must cover their content before removal.
  Keep provider events attached through provider close so final output is saved.
- **Snapshot/live boundary**: finish provider reads before capturing live state
  and its revision. The client buffers live events during a snapshot, discards
  covered additive text, and preserves newer events and informational warnings.
  Completed messages may precede durable history; keep them without replaying
  old completion transitions over newer drafts. Match them against provider
  history using the normal message reconciliation, since IDs can differ.
  Covered turn completions must still schedule the final history/Git refresh.
  Drain buffered events on errors.
  Keep finished tool overlays until provider history confirms their content;
  clearing at turn completion can lose updates from a snapshot already reading.
- **Client session aliases**: `session_identity_store.dart` retains host ownership
  for offline use. `SessionLocalStore.adoptSessionAliases` moves cache rows in a
  transaction; new writes normalize IDs too. Keep the original IDs on pending
  sends and resolve aliases for lookup/removal. Preference edits must remove
  equivalent old keys, so clearing a choice cannot restore an older value.
- **Cached session verification**: cached transcripts remain stale until a full
  snapshot succeeds. Provider timestamps may be coarse and existing rows can
  change without a new transcript sequence number.
- **Client storage**: transcripts and pending sends use the existing SQLite
  database. Import preferences and the import marker in one transaction; keep
  the source preferences as a backup. Clearing data must keep the marker so
  that old messages and favorites cannot return. Pending sends have no expiry
  and must never be evicted to make space. Reject a save that exceeds capacity.
  Match sent messages by client input identity, never by repeated text and time.
- **Workspace sandboxing**: `resolveWorkspacePath` uses `realpath` and prefix
  match against workspace roots. `WorkspaceAccessError` extends `Error` with
  a `status` field (default 403) that HTTP handlers can throw directly. Roots
  come from the explicit `workspaceRoots` config plus known session working
  directories; unknown sessions fail closed, and the environment override is
  the comma-separated `SIDEMESH_WORKSPACE_ROOTS` list.
- **Terminal security**: `SIDEMESH_TOKEN` is deleted from env before spawning
  the shell; `SIDEMESH_TERMINAL_SESSION=1` is injected.
- **ACP terminal sign-in**: advertise `auth.terminal` only with an explicit
  executable/argument configuration and an enabled host terminal service. Run
  the configured program separately, append the supplied auth arguments, and
  never pass a terminal method ID to ACP `authenticate`. The host terminal ID
  belongs in the pending action; arguments, environment values, and output
  must stay out of transcripts. Open the exact terminal ID and remove its
  replay output on exit. Do not replace it with a shell or reuse it by cwd.
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

- **iOS APNs profiles**: enabling Push Notifications invalidates the assumptions
  of older provisioning profiles. Create and install a fresh App Store profile,
  then verify it contains `aps-environment = production` before archiving.

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

Managed Bleeding Edge self-updates are staged as detached Git worktrees under
`SIDEMESH_STATE_DIR/releases/<sha>`. That release root must resolve outside the
active checkout. Targets must come from the CI-published
`refs/heads/bleeding-edge` ref, never directly from `main`. The updater builds
before stopping the old daemon, switches the service wrapper, health-checks the
candidate, and rewrites the wrapper to the previous package directory on
rollback. Keep service-install helpers able to target an explicit package
directory; the atomic updater depends on that.

## Quick References

- Provider contract: `docs/provider-adapter-contract.md`
- Dependency/runtime compatibility: `docs/dependency-runtime-compatibility.md`
- Contributing guide: `CONTRIBUTING.md`
- Release playbook: `docs/release-playbook.md`
- CI definition: `.github/workflows/ci.yml`
