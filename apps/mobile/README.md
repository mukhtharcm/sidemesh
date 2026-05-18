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
The signed production app also exposes `Settings -> App updates`, where users
can manually check for updates and choose whether Sparkle checks daily,
weekly, or monthly.

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
