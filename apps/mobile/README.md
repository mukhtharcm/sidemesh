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

## Live Activity Extension Notes

The Live Activity widget extension uses explicit version values in
`ios/SidemeshLiveActivityExtension/Info.plist`:

- `CFBundleShortVersionString = 1.0.0`
- `CFBundleVersion = 1`

Do not replace these with `$(MARKETING_VERSION)` or
`$(CURRENT_PROJECT_VERSION)` unless the extension target is also proven to
inherit those build settings for every Flutter flavor and simulator/device
build. The extension target does not reliably inherit Flutter's
`FLUTTER_BUILD_NAME` / `FLUTTER_BUILD_NUMBER` values.

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
