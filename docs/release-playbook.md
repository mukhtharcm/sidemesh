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
- `Release macOS App`: tag/manual workflow that builds the Flutter macOS app,
  packages `.zip` and `.dmg` artifacts, optionally signs with Developer ID,
  optionally notarizes/staples with Apple, and publishes a GitHub Release from
  `v*` tags.
- `Deploy Website`: deploys the static `web/` marketing site and Pages
  Functions to Cloudflare Pages when `web/**` changes on `main`.
- `Secret Scan`: manual gitleaks scan over full git history.

Store deployment is intentionally not configured yet. Add TestFlight and signed
Android workflows only after the signing/provisioning story is stable.

## Website Deploy

The marketing site lives in `web/` and deploys to Cloudflare Pages project
`sidemesh-site`.

Required GitHub Actions secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

The waitlist/admin runtime secrets and bindings live in Cloudflare, not GitHub
Actions:

- `DB`: D1 binding configured in `web/wrangler.toml`.
- `TURNSTILE_SECRET`: optional Turnstile verification secret.
- `ADMIN_PASS`: required for `/admin/*`.

Manual deploy:

```bash
gh workflow run "Deploy Website"
```

## macOS Release Workflow

The macOS workflow uses the same secret names as the other macOS apps in
`~/dev/experiments`:

- `BUILD_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `P12_PASSWORD`: password for the `.p12`.
- `KEYCHAIN_PASSWORD`: temporary CI keychain password.
- `SIGNING_IDENTITY`: exact Developer ID identity, for example
  `Developer ID Application: Example (TEAMID)`.
- `APPLE_ID`: Apple ID used for notarization.
- `APP_SPECIFIC_PASSWORD`: app-specific password for the Apple ID.
- `TEAM_ID`: Apple Developer Team ID.

Without signing secrets, the workflow still produces unsigned/ad-hoc artifacts
for internal smoke testing. With signing secrets only, it produces signed
artifacts. With signing and notary secrets, it notarizes and staples both the
app and DMG.

To create a release from a tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

To run manually without publishing a GitHub Release, use the
`Release macOS App` workflow and leave `publish_release` disabled.

To package locally:

```bash
VERSION=0.1.0 BUILD_NUMBER=1 npm run macos:release:package
```

For a signed local package:

```bash
VERSION=0.1.0 \
BUILD_NUMBER=1 \
SIGNING_IDENTITY="Developer ID Application: Example (TEAMID)" \
npm run macos:release:package
```

Prerelease versions such as `0.1.0-beta.1` are allowed for artifact names and
GitHub releases. The packaging script automatically uses the base `0.1.0` as
the macOS bundle short version unless `FLUTTER_BUILD_NAME` is set explicitly.

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
