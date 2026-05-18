# Sidemesh Mobile

Flutter client for connecting to Sidemesh hosts.

## iOS Flavors

The iOS project has two shared schemes so development and production builds can
be installed on the same iPhone.

| Flavor | Scheme | Display name | Bundle ID |
| --- | --- | --- | --- |
| Development | `dev` | `Sidemesh Dev` | `dev.sidemesh.mobile.dev` |
| Production | `prod` | `Sidemesh` | `dev.sidemesh.mobile` |

Run on a connected iPhone:

```bash
flutter run --flavor dev -t lib/main.dart
flutter run --flavor prod -t lib/main.dart
```

From the repository root:

```bash
npm run mobile:ios:dev
npm run mobile:ios:prod
```

Build checks without installing:

```bash
flutter build ios --flavor dev --debug --no-codesign
flutter build ios --flavor prod --release --no-codesign
```

The two flavors use different iOS bundle IDs, so iOS treats them as separate
apps. Local hosts, tokens, favorites, pins, theme, and other preferences are
stored separately by default.

## Android Flavors

The Android project now mirrors iOS with two product flavors so development
and production builds can be installed on the same device.

| Flavor | App name | Application ID |
| --- | --- | --- |
| Development | `Sidemesh Dev` | `dev.sidemesh.mobile.dev` |
| Production | `Sidemesh` | `dev.sidemesh.mobile` |

Run on a connected Android device:

```bash
flutter run --flavor dev -t lib/main.dart
flutter run --flavor prod -t lib/main.dart
```

From the repository root:

```bash
npm run mobile:android:dev
npm run mobile:android:prod
```

Build APKs without installing:

```bash
flutter build apk --flavor dev --debug
flutter build apk --flavor prod --release
```

The two Android flavors use different application IDs, so Android treats them
as separate apps. Local hosts, tokens, favorites, pins, theme, and other
preferences are stored separately by default.

## macOS Flavors

The macOS project mirrors iOS with shared `dev` and `prod` schemes.

| Flavor | Scheme | Display name | Bundle ID |
| --- | --- | --- | --- |
| Development | `dev` | `Sidemesh Dev` | `com.sidemesh.sidemeshMobile.dev` |
| Production | `prod` | `Sidemesh` | `com.sidemesh.sidemeshMobile` |

Run on macOS:

```bash
flutter run -d macos --flavor dev -t lib/main.dart
flutter run -d macos --flavor prod -t lib/main.dart
```

From the repository root:

```bash
npm run mobile:macos:dev
npm run mobile:macos:prod
```

Build checks:

```bash
flutter build macos --flavor dev --debug
flutter build macos --flavor prod --release
```

Production macOS release packaging builds the `prod` flavor by default.
The `dev` flavor uses a separate bundle ID and a separate macOS Keychain
service name so local debug builds do not keep touching production tokens.

Production macOS app updates use Sparkle when the release build embeds
`SIDEMESH_SPARKLE_PUBLIC_ED_KEY`. Sparkle checks the production appcast hosted
on the dedicated GitHub Release tag `macos-appcast-prod`; daemon update checks
remain separate and still happen through each connected Sidemesh host.

## Local iOS Signing

The committed Xcode project does not store a personal Apple development team
ID. Both the Runner target and the Live Activity extension read:

```text
DEVELOPMENT_TEAM = $(SIDEMESH_DEVELOPMENT_TEAM)
```

Create this ignored local file on machines that need to sign device builds:

```bash
cat > ios/Flutter/Signing.local.xcconfig <<'EOF'
SIDEMESH_DEVELOPMENT_TEAM = YOURTEAMID
EOF
```

This file is intentionally ignored by git. If it is missing, simulator builds
and `--no-codesign` checks still work, but release/device builds that require
signing will fail until the local team ID exists.

## Live Activity Extension Notes

The Live Activity widget extension has its own
`ios/Flutter/Extension.xcconfig`. It includes Flutter's generated build values
and the ignored local signing config, then maps them into the extension target:

- `MARKETING_VERSION = $(FLUTTER_BUILD_NAME)`
- `CURRENT_PROJECT_VERSION = $(FLUTTER_BUILD_NUMBER)`
- `DEVELOPMENT_TEAM = $(SIDEMESH_DEVELOPMENT_TEAM)`

Do not remove this extension xcconfig. Without it, the extension target can
miss Flutter's version settings even though the Runner target has them.

The extension target also needs the same resolved `DEVELOPMENT_TEAM` as the
Runner target. If Runner signs but the extension does not, release/device
builds fail with:

```text
Signing for "SidemeshLiveActivityExtension" requires a development team.
```

If this regresses, simulator install can fail after a successful Xcode build
with:

```text
Invalid placeholder attributes.
Failed to create app extension placeholder
bundleVersion must be set in placeholder attributes for an app extension placeholder
```

The build may still succeed; verify with a simulator install:

```bash
flutter build ios --simulator --flavor dev --debug
xcrun simctl install <simulator-id> build/ios/iphonesimulator/Runner.app
```

## Local macOS Signing

The committed macOS project defaults to ad-hoc signing for local builds when no
team is configured. That is enough to launch the app, but it can cause macOS
keychain prompts to reappear because the app does not have a stable Apple
development identity.

Create this ignored local file on machines that run signed macOS dev builds:

```bash
cat > macos/Flutter/Signing.local.xcconfig <<'EOF'
SIDEMESH_DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY = Apple Development
AD_HOC_CODE_SIGNING_ALLOWED = NO
EOF
```

This file is intentionally ignored by git. Do not commit your personal team ID.

After creating it, rebuild the dev flavor:

```bash
flutter run -d macos --flavor dev -t lib/main.dart
```

You can confirm the build is no longer ad-hoc with:

```bash
cd macos
xcodebuild -showBuildSettings -scheme Runner -configuration Debug-dev \
  | egrep 'DEVELOPMENT_TEAM|CODE_SIGN_IDENTITY|EXPANDED_CODE_SIGN_IDENTITY|AD_HOC_CODE_SIGNING_ALLOWED'
```

The expected result is a non-empty `DEVELOPMENT_TEAM`, a real
`EXPANDED_CODE_SIGN_IDENTITY`, and `AD_HOC_CODE_SIGNING_ALLOWED = NO`.

## macOS Release CI Signing

Local macOS development signing and release signing are separate.

The release workflow in `.github/workflows/release-macos.yml` does this:

1. builds the Flutter macOS app for the `prod` flavor
2. imports a Developer ID certificate from GitHub secrets
3. re-signs the built `.app` and `.dmg` with `SIGNING_IDENTITY`
4. notarizes the ZIP and DMG with Apple credentials
5. staples the notarization tickets
6. publishes Sparkle metadata when the release run includes those secrets

So CI does not depend on your local `Signing.local.xcconfig`. It uses
Developer ID signing from workflow secrets and then notarizes the release
artifacts.
