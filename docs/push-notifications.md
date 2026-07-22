# iOS Push Notifications

Sidemesh uses Apple Push Notification service (APNs) directly. Firebase Cloud
Messaging is not required.

## Data flow

1. The iOS app asks APNs for a device token.
2. The app registers that token with the Cloudflare push relay. The relay
   returns two random capabilities: a publish token and a management token.
3. The app keeps both capabilities in the iOS Keychain and sends only the
   publish token to each enabled Sidemesh host over the existing authenticated
   host connection.
4. The daemon writes notification work to its private state directory before
   attempting delivery. It retries transient relay failures for up to 24 hours.
5. The relay stores the event in D1, sends it through a Cloudflare Queue, and
   signs the APNs request with the server-only `.p8` key.
6. Tapping an alert routes back to the matching host, session, and approval.

The supported remote events are `approval_required`, `input_required`,
`turn_completed`, and `turn_failed`. Alerts intentionally contain generic text;
prompts, answers, file contents, and host credentials are never sent to APNs.

## Relay resources

The worker lives in `push-relay/` and needs one D1 database, a delivery queue,
and a dead-letter queue. Its non-secret resource bindings are committed in
`push-relay/wrangler.jsonc`.

Create an Apple APNs authentication key in the Apple Developer portal and set
these Worker secrets:

```bash
cd push-relay
npx wrangler secret put APNS_KEY_ID
npx wrangler secret put APNS_TEAM_ID
npx wrangler secret put APNS_PRIVATE_KEY
```

`APNS_PRIVATE_KEY` is the complete downloaded `.p8` file. It can be downloaded
only once. Store a protected backup outside the repository.

Apply migrations and deploy:

```bash
cd push-relay
npm ci
npm run check
npm test
npx wrangler d1 migrations apply sidemesh-push-relay --remote
npx wrangler deploy
```

The production app uses `https://push.sidemesh.com`. Development builds can
override it with:

```bash
flutter run --flavor dev \
  --dart-define=SIDEMESH_PUSH_RELAY_URL=https://example.workers.dev
```

## Reliability and security

- The daemon outbox is written atomically with private file permissions.
- Daemon-to-relay and relay-to-APNs delivery are both idempotent.
- Retryable failures use delayed retries; invalid or revoked device tokens are
  disabled instead of retried forever.
- Publish and management capabilities are stored as SHA-256 hashes in D1.
- The relay accepts only the configured Sidemesh bundle IDs and validates event
  shape, size, and expiry.
- Cloudflare rate-limit bindings protect public registration and each publish
  capability from request floods.
- The daemon itself remains private. Only the narrow relay is internet-facing.
- Notification delivery is best effort: Apple can still delay or suppress an
  alert because of Focus modes, device state, or user notification settings.

macOS continues using local notifications while the app or background sync is
running. It does not need the relay for the iOS-only rollout.
