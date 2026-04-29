# Release Playbook

Sidemesh is private developer-preview software right now. This playbook is for
trusted testers and your own hosts; it is not a public OSS release process.

## Release Position

- Repository: private.
- License: intentionally not chosen yet.
- npm: not published; `package.json` remains `"private": true`.
- Daemon distribution: private GitHub install or local clone.
- App distribution: local Flutter builds and manual GitHub Actions artifacts.
- Recommended network: Tailscale or trusted private LAN.

## Preflight

Run these before cutting a preview build:

```bash
npm ci
npm run typecheck
npm run test:server
npm run build
npm pack --dry-run

cd apps/mobile
flutter pub get
flutter test
flutter analyze
```

Before any public repository visibility change, run a full history scan:

```bash
npm run secret:scan
scripts/secret-scan.sh --history
```

The manual GitHub Actions workflow `Secret Scan` runs gitleaks against full git
history and should also pass before public release.

## Daemon Install From Private GitHub

On a trusted host with access to the private repo:

```bash
npm install -g github:your-org/sidemesh
sidemesh setup
sidemesh doctor
sidemesh service install
sidemesh pair
```

On Linux/systemd, use sudo for service install/restart/uninstall:

```bash
sudo sidemesh service install
sudo sidemesh service restart --yes
sudo sidemesh service uninstall --yes
```

On macOS/LaunchAgent, do not use sudo:

```bash
sidemesh service install
sidemesh service restart --yes
sidemesh service uninstall --yes
```

## Updating Existing Hosts

For a repo clone:

```bash
git pull --ff-only
npm install
npm run build
sidemesh service restart --yes
```

For a global private GitHub install:

```bash
npm install -g github:your-org/sidemesh
sidemesh service restart --yes
```

If the daemon is foreground-managed instead of service-managed:

```bash
sidemesh restart --yes
```

## GitHub Actions Builds

Current workflows:

- `CI`: runs server typecheck/tests/build/package dry-run plus focused Flutter
  tests and analysis on pull requests and `main`.
- `Mobile Artifacts`: manual workflow that builds an Android debug APK, a macOS
  debug app, and an iOS simulator app. These are unsigned development artifacts.
- `Secret Scan`: manual gitleaks scan over full git history.

Store deployment is intentionally not configured yet. Add TestFlight, signed
macOS, and signed Android workflows only after the signing/provisioning story is
stable.

## Security Caveats For Testers

Tell every tester:

- Use Sidemesh only over Tailscale/private LAN.
- Do not expose the daemon to the public internet.
- The token is a shared bearer secret; rotate it if copied or leaked.
- Terminal access is optional and powerful; enable it only on hosts you trust.
- Filesystem and git features operate directly on the host workspace.

## Release Checklist

- [ ] `main` is green in GitHub Actions.
- [ ] Local `npm pack --dry-run` looks correct.
- [ ] Secret scan has been run for the release boundary.
- [ ] README reflects the intended distribution path.
- [ ] VPSes/macOS hosts were updated with `sidemesh service restart --yes`.
- [ ] Mobile artifacts were built from the intended commit.
- [ ] Testers received the correct host URL/token instructions.
