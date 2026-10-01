# SignalWord iOS app

This directory contains the Swift 6/iOS 18 application and its platform-independent alert core. Keep the app target named `SignalWord`; `SafeWord` remains the legacy planning codename in existing documents.

The checked-in Xcode project uses this source layout:

```text
SignalWord/
  App/             app entry point and composition root
  Core/            configuration, logging, security
  Domain/          alerts, contacts, readiness, subscriptions
  Services/        API, App Intents, location, persistence, payments
  Features/        user-facing SwiftUI flows
  DesignSystem/    shared semantic UI components
  Tests/           unit and integration tests
```

## Build and verify

```sh
xcodebuild -version
xcode-select -p
swift run --package-path apps/ios SignalWordCoreVerification
xcodebuild -project apps/ios/SignalWord.xcodeproj -scheme SignalWord \
  -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

The package verifier covers durable command/idempotency behavior and location freshness boundaries. The Xcode build covers the real SwiftUI app, Keychain session rotation, lifecycle API, device authentication, locked App Intent integration, and Core Location integration.

Location is optional and requested only with clear user action. A fresh cached sample may be included in the initial request; after server acceptance the app makes one time-bounded best-effort request and appends the result through `POST /v1/alerts/{eventId}/locations`. Denial, timeout, invalid coordinates, stale data, or GPS failure never blocks the alert.

See [the evaluator guide](../../JUDGE_GUIDE.md) for required verification/RevenueCat settings, the pinned backend guard, independent deployment and the controlled TEST walkthrough.

## Environment configuration

The app fails closed when configuration is absent. Inject these user-defined build settings through the signed build/CI environment; do not commit production values:

```text
SIGNALWORD_SUPABASE_URL=https://<project-ref>.supabase.co
SIGNALWORD_SUPABASE_PUBLISHABLE_KEY=<project publishable key>
SIGNALWORD_USER_API_URL=https://<project-ref>.supabase.co/functions/v1/user-api
```

Release builds require HTTPS. The publishable key is intentionally a client-side key; a Supabase secret/service-role key must never be embedded. Registration and password sign-in use the configured CAPTCHA verification flow. Rotating access/refresh tokens are stored in ThisDeviceOnly Keychain storage; a temporary refresh failure must not silently replace an existing identity.

The checked-in app uses `com.signalword.app` and `group.com.signalword.shared`. For your own device build, use your own signing team and owned identifiers, then verify a clean signed install. The App Group entitlement must match the App Intent host so both processes share the same durable idempotency record.
