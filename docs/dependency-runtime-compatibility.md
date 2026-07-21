# Dependency and runtime compatibility

Last audited: 2026-07-21.

Sidemesh combines ordinary library dependencies with external agent runtimes.
An `outdated` result is therefore an audit queue, not an instruction to update
every package: provider APIs, native binaries, Termux support, and long-running
daemon processes all need separate compatibility checks.

## Audited current surfaces

| Surface | Audited version or policy | Status |
|---|---|---|
| Node.js | `>=22.19.0`; CI uses Node 24 | Current |
| Codex CLI/app-server | `0.144.6` | Compatible; see `docs/codex-app-server-compatibility.md` |
| OpenCode | `1.18.4` | Compatible; the real adapter passed health, session, model, mode, and skill smoke checks |
| GitHub Copilot CLI | `1.0.73` | Current; also enforced through the root npm override |
| ACPx | `0.12.0` | Current |
| Flutter | CI and release workflows use `3.44.7`; the app requires Flutter `>=3.44.0` and Dart `^3.12.0` | Current |

Codex and OpenCode are host-installed executables rather than npm dependencies
of the published Sidemesh package. Updating a global executable does not update
an already-running provider process. Deploy the rebuilt daemon, then restart a
service-managed host from an independent shell or other out-of-band mechanism.
Never restart the Sidemesh service from a session running inside that service.

## Intentional pins

### Pi coding agent `0.80.3`

The current adapter depends on the Pi service surface exported by `0.80.3`.
Pi `0.80.10` no longer exposes the `modelRegistry` shape used by Sidemesh, so a
version-only bump does not compile. Upgrade Pi only together with an adapter
migration and focused provider tests.

Pi also ships an npm shrinkwrap that pins vulnerable transitive versions.
`scripts/patch-pi-transitives.mjs` replaces only the audited packages after
install:

- `brace-expansion` `5.0.7`
- `protobufjs` `7.6.5`

Keep those root dependencies exact. `protobufjs` 8 is not a drop-in replacement
for Pi's `^7.5.4` consumer constraint.

### GitHub Copilot SDK `1.0.4`

The SDK stays exact at `1.0.4`. Version `1.0.7` adds Koffi native FFI packages,
but the published platform set does not include Android/Termux. Sidemesh must
remain installable when native `node-pty` support is unavailable, so do not
accept the SDK bump until its dependency graph has an Android-compatible path
or the adapter isolates the native feature.

The Copilot CLI itself is independently held at the compatible `1.0.73` line by
the root npm override.

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
