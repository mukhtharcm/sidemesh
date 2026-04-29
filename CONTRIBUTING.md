# Contributing

Sidemesh is currently a private developer-preview project. Contributions are
limited to trusted collaborators until the license and public distribution model
are decided.

## Development Setup

```bash
npm install
npm run mobile:get
npm run build
npm run test:server
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
flutter test
flutter analyze
```

## Code Guidelines

- Keep provider-specific behavior inside provider adapters.
- Prefer host-owned features for filesystem, git, and terminal capabilities
  when the behavior does not require a specific agent provider.
- Do not add new provider-specific fields to client models unless the provider
  abstraction cannot express the concept.
- Keep terminal, filesystem, and approval changes conservative; these are
  high-trust host-control surfaces.
- Never commit real tokens, hostnames that should stay private, generated
  service env files, signing profiles, certificates, or local app-store keys.

## Distribution

Do not publish npm, app-store, TestFlight, or GitHub release artifacts without
checking `docs/release-playbook.md`.
