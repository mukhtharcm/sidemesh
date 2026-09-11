# Dependency and runtime compatibility

Last architecture compatibility check: 2026-09-11.

Sidemesh combines ordinary library dependencies with external agent runtimes.
An `outdated` result is therefore an audit queue, not an instruction to update
every package: provider APIs, native binaries, Termux support, and long-running
daemon processes all need separate compatibility checks.

## Audited current surfaces

| Surface | Audited version or policy | Status |
|---|---|---|
| Node.js | `>=22.19.0`; CI uses Node 24 | Current |
| Codex CLI/app-server | `0.144.6` schema; native history also checked on `0.154.0` | Compatible; see `docs/codex-app-server-compatibility.md` |
| OpenCode SDK/server | `1.18.4` / `1.18.4` | Official SDK requests and SSE; isolated native checks cover health, session history, model/mode/skill catalogs, archive, and shutdown |
| GitHub Copilot CLI | `1.0.73` | Current; also enforced through the root npm override |
| ACP SDK | `1.4.0`, protocol 1 | Direct optional ACP adapter; see [support matrix](acp-support-matrix.md) |
| Flutter | CI and release workflows use `3.44.7`; the app requires Flutter `>=3.44.0` and Dart `^3.12.0` | Current |

Codex and OpenCode are host-installed executables rather than npm dependencies
of the published Sidemesh package. Updating a global executable does not update
an already-running provider process. Deploy the rebuilt daemon, then restart a
service-managed host from an independent shell or other out-of-band mechanism.
Never restart the Sidemesh service from a session running inside that service.

## Intentional pins

### Pi coding agent `0.85.1`

Pi runs in its official RPC process. Sidemesh uses the exported RPC wire types
and the documented JSONL protocol, including `agent_settled` and extension UI
requests. The public SDK is loaded only for native history and catalog reads.
Do not use private session queues or SDK execution internals.

The version is exact so protocol changes must pass the RPC boundary tests.
This version contains the transitive dependency fixes that previously needed
a Sidemesh install script. A clean install no longer copies packages into Pi.

### GitHub Copilot SDK `1.0.4`

The SDK stays exact at `1.0.4`. Version `1.0.7` adds Koffi native FFI packages,
but the published platform set does not include Android/Termux. Sidemesh must
remain installable when native `node-pty` support is unavailable, so do not
accept the SDK bump until its dependency graph has an Android-compatible path
or the adapter isolates the native feature.

The Copilot CLI itself is independently held at the compatible `1.0.73` line by
the root npm override.

Copilot history reads use `getEvents()` on every full refresh. SQLite retains
recovery items until native replay confirms them, including the native ID from
`send()`. The old `sessions.json` is an import source only. The adapter uses
`metadata.activity()` for native execution status and waits for `session.idle`,
because `assistant.turn_end` can precede another tool cycle. Run
`SIDEMESH_TEST_COPILOT=1 node --import tsx --test src/copilot-provider.test.ts`
for the isolated SDK/CLI check. It creates an empty session with a temporary
`COPILOT_HOME` and sends no model prompt.

### OpenCode SDK `1.18.4`

Use the official SDK and global event stream. OpenCode owns its native history;
Sidemesh keeps recovery records in the host session database. `stateDir` still
sets the native XDG roots. The owned server uses a temporary local password.
Assistant completion does not end a tool cycle; wait for native idle status.
On reconnect, refresh loaded sessions and pending requests. There is no idle
history poller. Run the optional isolated native check with
`SIDEMESH_TEST_OPENCODE_BIN=/path/to/opencode node --import tsx --test src/opencode-provider.test.ts`.
It creates empty sessions and sends no model prompt.

### TypeScript 6

TypeScript 7.0.2 compiles the server on supported desktop Linux, but its npm
distribution resolves the compiler through platform-specific native packages
and has no Android target or JavaScript fallback. Retain TypeScript 6 until the
published compiler can run on Termux or Sidemesh deliberately drops that
installation target.

### Flutter plugin majors

`device_info_plus` 13, `package_info_plus` 10, and `wakelock_plus` 1.6 require
`win32` 6. The newest stable `file_picker` 11.0.2 still requires `win32` 5; its
compatible next line is prerelease-only. Keep the newest mutually resolvable
stable versions and retain Flutter's generated `android.builtInKotlin=false`
and `android.newDsl=false` compatibility flags. Revisit the three majors after
a compatible stable `file_picker` release.

## Upgrade audit procedure

1. Run `npm outdated` and `flutter pub outdated` from a clean checkout.
2. Separate ordinary semver-compatible updates from the pins documented above.
3. For Codex, generate and diff the stable app-server schema using the procedure
   in `docs/codex-app-server-compatibility.md`.
4. For OpenCode, start the candidate executable through
   `OpenCodeAgentProvider` with an isolated state directory and exercise health,
   sessions, models, modes, and skills.
5. Inspect every new native or optional dependency for Linux, macOS, Windows,
   Android/Termux, and supported Flutter platform coverage.
6. Run the server and Flutter pre-merge gates from `AGENTS.md` before merging.
7. Treat deployment as a separate operation; verify the running service version
   only after an out-of-band restart.

Useful upstream references include the
[Codex app-server documentation](https://learn.chatgpt.com/docs/app-server),
[GitHub Copilot SDK compatibility guide](https://docs.github.com/en/copilot/how-tos/copilot-sdk/troubleshooting/compatibility),
and the [Flutter release changelog](https://github.com/flutter/flutter/blob/master/CHANGELOG.md).
