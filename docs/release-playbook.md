# Release Playbook

Sidemesh is Apache-2.0 licensed open-source software, but its daemon still
belongs on trusted networks. This playbook stays conservative about release
and distribution because the product exposes powerful host-control surfaces.

## Release Position

- Repository: public.
- License: Apache-2.0.
- npm: not published yet, but the package metadata is publish-ready.
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

## Daemon Install From GitHub

On a trusted host that should consume the repo directly before npm publishing:

```bash
npm install -g github:mukhtharcm/sidemesh
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

For a global GitHub install:

```bash
npm install -g github:mukhtharcm/sidemesh

# macOS
sidemesh service restart --yes

# Linux
sudo sidemesh service restart --yes
```

For a detached background daemon started with `sidemesh start`:

```bash
sidemesh stop --yes
git pull --ff-only
npm install
npm run build
sidemesh start
```

For a foreground daemon started with `sidemesh daemon`, stop the terminal
process, update the checkout, rebuild, and start it again manually.

App-driven restart and self-update are recommended only on service-managed
hosts.

## GitHub Actions Builds

Current workflows:

- `CI`: runs server typecheck/tests/build/package dry-run plus focused Flutter
  tests and analysis on pull requests and `main`.
- `Mobile Artifacts`: manual workflow that builds an Android debug APK, a macOS
  debug app, and an iOS simulator app. These are unsigned development artifacts.
- `Release macOS App`: manual workflow that builds the Flutter macOS app,
  packages `.zip` and `.dmg` artifacts, optionally signs with Developer ID,
  optionally notarizes/staples with Apple, and can publish a GitHub Release
  when `publish_release` is enabled.
- `Deploy to TestFlight`: manual workflow that builds and uploads the signed iOS
  prod flavor. It is intentionally not tied to tags so server releases do not
  spend macOS CI minutes.
- `Deploy Website`: deploys the static `web/` marketing site and Pages
  Functions to Cloudflare Pages when `web/**` changes on `main`.
- `Publish npm Package`: publishes the daemon package to npm on manual dispatch
  or when a GitHub Release with tag `npm-v<package.json version>` is published.
  It currently uses the `NPM_TOKEN` GitHub Actions secret for the first publish
  and early releases.
- `Secret Scan`: manual gitleaks scan over full git history.

## npm Publish Setup

The npm workflow assumes:

- package name: `sidemesh`
- GitHub environment name: `npm`
- GitHub Actions secret: `NPM_TOKEN`

Before the first publish:

1. Create or log into the npm user account that will own `sidemesh`.
2. Add an npm publish token to the repository Actions secrets as `NPM_TOKEN`.
3. Create the `npm` GitHub environment in this repository.
4. Confirm the package version in `package.json` is the version you want to
   publish.

To publish the daemon package from a GitHub Release, create a release tag that
matches `package.json` with an `npm-v` prefix, for example `npm-v0.1.2`.
macOS app releases and appcast releases intentionally do not publish npm.

After the first successful npm publish, switch to npm trusted publishing and
remove the long-lived token if you want a tighter setup.

Store deployment is intentionally opt-in. Run TestFlight only when you actually
need a mobile build. Keep product releases separate:

- npm daemon package: publish manually or with `npm-v<daemon version>`.
- macOS app: run `Release macOS App` manually and enable `publish_release`.
- iOS app: run `Deploy to TestFlight` manually.

## Website Deploy

The marketing site lives in `web/` and deploys to Cloudflare Pages project
`sidemesh`.

Required GitHub Actions secrets:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ACCOUNT_ID`

The site now includes a Cloudflare Pages waitlist flow again. Production setup
needs:

- a `DB` D1 binding wired to a `waitlist` table
- `TURNSTILE_SECRET` Pages secret if Turnstile should be enforced
- `ADMIN_PASS` Pages secret for `/admin`
- `PUBLIC_TURNSTILE_SITE_KEY` available at build time for the landing page form

The deploy action publishes the built Astro site. Pages Functions are picked up
from `web/functions/`, but the D1 binding and runtime secrets still need to be
configured in the Cloudflare Pages project.

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
- `SPARKLE_PUBLIC_ED_KEY`: Sparkle EdDSA public key embedded into the macOS
  app. This key is not secret, but the workflow reads it from Actions secrets
  so app updates stay disabled until update signing is configured.
- `SPARKLE_PRIVATE_KEY_BASE64`: base64-encoded Sparkle EdDSA private key file
  used to sign appcast update enclosures. Never commit this value.

Without signing secrets, the workflow still produces unsigned/ad-hoc artifacts
for internal smoke testing. With signing secrets only, it produces signed
artifacts. With signing and notary secrets, it notarizes and staples both the
app and DMG.

With signing secrets, notary secrets, and Sparkle secrets, the workflow also
generates `appcast-prod.xml` from the signed/notarized ZIP and uploads it to the
dedicated GitHub Release tag `macos-appcast-prod`. Production macOS builds read
this stable feed URL:

```text
https://github.com/mukhtharcm/sidemesh/releases/download/macos-appcast-prod/appcast-prod.xml
```

Each appcast entry points back to the versioned GitHub Release ZIP. The DMG
remains the manual first-install artifact.

To create a GitHub Release from the macOS workflow, run it manually and enable
`publish_release`. npm tags intentionally do not trigger app builds.

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
