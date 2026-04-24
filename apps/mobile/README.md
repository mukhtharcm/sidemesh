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
