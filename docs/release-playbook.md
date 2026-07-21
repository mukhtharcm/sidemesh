# Release Playbook

Sidemesh is Apache-2.0 licensed open-source software, but its daemon still
belongs on trusted networks. This playbook stays conservative about release
and distribution because the product exposes powerful host-control surfaces.

## Release Position

- Repository: public.
- License: Apache-2.0.
- npm: published as the `sidemesh` package.
- Daemon distribution: npm or local clone.
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

## Daemon Install From npm

On a trusted host that should consume the published package:

```bash
npm install -g sidemesh @openai/codex
sidemesh up
sidemesh service install
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

For a repo clone managed by `launchd` or `systemd`:

```bash
git pull --ff-only
npm install
npm run build

# macOS
sidemesh service restart --yes

# Linux
sudo sidemesh service restart --yes
```

For a global npm install:

```bash
npm install -g sidemesh@latest

# macOS
sidemesh service restart --yes

# Linux
sudo sidemesh service restart --yes
```

For a detached background daemon started with `sidemesh start`:

```bash
sidemesh stop --yes
npm install -g sidemesh@latest
sidemesh up
```

For a foreground daemon started with `sidemesh daemon`, stop the terminal
process, update the checkout, rebuild, and start it again manually.

App-driven restart and self-update are recommended only on service-managed
hosts.

### Managed Bleeding Edge Updates

On a service-managed Git install, the Bleeding Edge channel uses atomic release
directories instead of mutating the live checkout. The updater fetches and pins
the target commit, creates a detached worktree under
`<stateDir>/releases/<commit-sha>`, runs `npm ci` and the production build while
the old daemon remains online, then switches the service wrapper. It considers
the update successful only after the new daemon passes its health check.

If cutover or verification fails, the updater rewrites the wrapper to the
previous package directory, starts it, and verifies that the previous daemon is
healthy. It keeps the current and previous release worktrees and removes older
ones after a later successful update. The state directory must resolve outside
the active Git checkout; nested worktrees are rejected.

The authenticated `GET /api/admin/update-status` endpoint exposes the latest
operation and its phase (`staging`, `stopping`, `switching`, `starting`,
`verifying`, or `rolling_back`). The update status and lock files live in the
state directory with private permissions. Stable-channel and unmanaged updates
continue to use the in-place path and require a clean tracked Git checkout.

## GitHub Actions Builds

Current workflows:

- `CI`: runs server typecheck/tests/build/package dry-run plus focused Flutter
  tests and analysis on pull requests and `main`.
- `Mobile Artifacts`: manual workflow that builds an Android debug APK, a macOS
  debug app, and an iOS simulator app. These are unsigned development artifacts.
- `Release macOS App`: manual workflow that builds the Flutter macOS app,
  packages `.zip` and `.dmg` artifacts, optionally signs with Developer ID,
  optionally notarizes/staples with Apple, and can publish a GitHub Release
  when `publish_release` is enabled. It uses the committed
  `apps/mobile/pubspec.yaml` version.
- `Deploy to TestFlight`: manual workflow that builds and uploads the signed iOS
  prod flavor from the committed `apps/mobile/pubspec.yaml` version. It is
  intentionally not tied to tags so server releases do not spend macOS CI
  minutes.
- `Deploy Website`: deploys the static `web/` marketing site and Pages
  Functions to Cloudflare Pages when `web/**` changes on `main`.
- `Publish npm Package`: publishes the daemon package to npm on manual dispatch
  or when a GitHub Release with tag `npm-v<package.json version>` is published.
  It uses npm trusted publishing from GitHub Actions.
- `Secret Scan`: manual gitleaks scan over full git history.

## npm Publish Setup

The npm workflow assumes:

- package name: `sidemesh`
- GitHub environment name: `npm`
- npm trusted publisher: GitHub Actions, repository `mukhtharcm/sidemesh`,
  workflow filename `publish-npm.yml`, environment `npm`, allowed action
  `npm publish`

Before publishing:

1. Confirm the package version in `package.json` is the version you want to
   publish.
2. Confirm the `npm` GitHub environment exists.
3. Confirm the npm trusted publisher configuration matches the workflow.

To publish the daemon package from a GitHub Release, create a release tag that
matches `package.json` with an `npm-v` prefix, for example `npm-v0.1.2`.
macOS app releases and appcast releases intentionally do not publish npm.

Do not use long-lived npm publish tokens for routine releases. If a token was
used for emergency publishing, revoke it after trusted publishing is restored.

Store deployment is intentionally opt-in. Run TestFlight only when you actually
need a mobile build. Keep product releases separate:

- npm daemon package: publish manually or with `npm-v<daemon version>`.
- macOS app: run `Release macOS App` manually and enable `publish_release`.
- iOS app: run `Deploy to TestFlight` manually.

## Mobile App Versioning

`apps/mobile/pubspec.yaml` is the only source of truth for official iOS and
macOS app release versions. The value must be stable `X.Y.Z+N`, where `X.Y.Z`
is the marketing version and `N` is the positive build number.

Before running TestFlight or macOS release workflows, bump and commit the mobile
version in a PR:

```bash
npm run mobile:version -- 1.1.1+1
```

The bump script refuses version downgrades and refuses reused or lower build
numbers when the marketing version stays the same. Official iOS and macOS
release workflows do not accept version or build-number inputs, and they do not
derive app versions from git tags.

The TestFlight workflow also checks App Store Connect before upload. It fails
if the committed pubspec version is older than an existing App Store Connect
version, or if the committed build number is not greater than the latest
uploaded build for the same version.

The macOS workflow checks the existing production Sparkle appcast before
publishing a new appcast. It refuses to replace the feed with an older version,
or with a reused/lower build number for the same version.

## Website Deploy

The marketing site lives in `web/` and deploys to Cloudflare Pages project
`sidemesh`.

Required GitHub Actions secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

The site is static and does not collect waitlist or analytics data. The deploy
action publishes the built Astro site; there are no Pages Functions, runtime
secrets, or database bindings to configure.

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
- `TEAM_ID`: Apple Developer Team ID used by notarization. Do not inject it
  into Developer ID app entitlements; macOS 26 rejects GUI launches when
  restricted app-identifier entitlements are present without a matching profile.
- `SPARKLE_PUBLIC_ED_KEY`: Sparkle EdDSA public key embedded into the macOS
  app. This key is not secret, but the workflow reads it from Actions secrets
  so app updates stay disabled until update signing is configured.
- `SPARKLE_PRIVATE_KEY_BASE64`: base64-encoded Sparkle EdDSA private key file
  used to sign appcast update enclosures. Never commit this value.

Without signing secrets, the workflow still produces unsigned/ad-hoc artifacts
for internal smoke testing. With signing secrets only, it produces signed
artifacts. With signing and notary secrets, it notarizes and staples both the
app and DMG.

Developer ID packaging must sign with
`apps/mobile/macos/Runner/Release.entitlements` directly. Do not inject
`com.apple.application-identifier` or
`com.apple.developer.team-identifier` into the app entitlements; `TEAM_ID`
belongs only in the notarization step. macOS 26 launchd/AMFI rejects a
Developer ID GUI app that claims those restricted entitlements without a
matching provisioning profile.

With signing secrets, notary secrets, and Sparkle secrets, the workflow also
generates `appcast-prod.xml` from the signed/notarized ZIP and uploads it to the
dedicated GitHub Release tag `macos-appcast-prod`. Production macOS builds read
this stable feed URL:

```text
https://github.com/mukhtharcm/sidemesh/releases/download/macos-appcast-prod/appcast-prod.xml
```

Each appcast entry points back to the versioned GitHub Release ZIP. The DMG
remains the manual first-install artifact.

To create a GitHub Release from the macOS workflow, bump
`apps/mobile/pubspec.yaml`, merge that change to `main`, run the workflow
manually, and enable `publish_release`. The release tag is
`macos-v<pubspec-version>`, for example `macos-v1.1.1+1`. npm tags
intentionally do not trigger app builds.

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

To embed the Sparkle public key in a local release build, add:

```bash
SIDEMESH_SPARKLE_PUBLIC_ED_KEY="base64-public-ed-key"
```

Prerelease versions such as `0.1.0-beta.1` are allowed only for local artifact
names and ad-hoc packaging. Official GitHub Actions app releases require the
committed pubspec version to be stable `X.Y.Z+N`.

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
