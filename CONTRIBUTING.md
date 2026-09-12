# Contributing

Sidemesh is open source under Apache-2.0. Contributions are still reviewed
conservatively because the daemon exposes high-trust host-control surfaces.

## Development Setup

```bash
npm install
npm run mobile:get
npm run typecheck
npm run test:server
npm run build
```

Run the daemon locally:

```bash
npm run setup
npm run daemon
```

For day-to-day daemon testing, prefer the compiled CLI path:

```bash
npm run build
npm link
sidemesh setup
sidemesh start
sidemesh pair
```

## Quality Gates

Before merging, run the relevant checks:

```bash
npm run typecheck
npm run test:server
npm run build
npm pack --dry-run
```

For Flutter changes:

```bash
cd apps/mobile
flutter pub get
flutter analyze
cd ../..
python3 scripts/check_flutter_theme.py
cd apps/mobile
flutter test
cd ../..
bash scripts/test-flutter-web-storage.sh
```

## Code Guidelines

- Keep provider-specific behavior inside provider adapters. Use Pi RPC, Codex
  app-server, the Copilot SDK, or the OpenCode SDK for their native providers.
  The optional ACP adapter uses the ACP SDK directly.
- Route sessions by configured instance ID, not provider kind. The session
  coordinator owns the published view and durable input dispatch. Keep native
  history with the agent and preserve unconfirmed local output. See the
  [provider contract](docs/provider-adapter-contract.md) and
  [storage ownership](docs/session-storage.md).
- Prefer host-owned features for filesystem, git, and terminal capabilities
  when the behavior does not require a specific agent provider.
- Do not add new provider-specific fields to client models unless the provider
  abstraction cannot express the concept.
- Use `/api/node.defaultProviderCapabilities` for default-provider features and
  `supportedProviders[].capabilities` for a selected provider.
- Session recovery uses a bounded snapshot, with live events for ongoing work.
  See [session synchronization](docs/session-synchronization.md).
- Provider adapters should not implement filesystem operations; local filesystem
  is daemon-owned in `src/fs-routes.ts` and advertised through `hostCapabilities`.
- Keep terminal, filesystem, and approval changes conservative; these are
  high-trust host-control surfaces.
- Never commit real tokens, hostnames that should stay private, generated
  service env files, signing profiles, certificates, or local app-store keys.

## Distribution

Do not publish npm, app-store, TestFlight, or GitHub release artifacts without
checking `docs/release-playbook.md`.
