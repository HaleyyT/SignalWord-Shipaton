# Optional crash SDK: local integration verified

The package uses official Sentry 9.29.0 with its pinned SHA-256. Swift Package Manager successfully downloaded and validated the artifact on 29 September 2026.

Use `SIGNALWORD_WITH_SENTRY=1 swift test --package-path apps/ios` to run the actual serializer privacy test. Without that environment variable the package deliberately tests the SDK-unavailable fallback instead. Both paths are maintained; the SDK-enabled CI job prevents the fallback from concealing integration errors.

SDK-enabled compilation exposed UIKit-only options in the macOS test target. Those options are guarded by `canImport(UIKit)`; they remain explicitly disabled in the iOS app. The SDK serializer privacy regression and an SDK-linked Release simulator build passed. See the current release-readiness report for exact application journey results.

No DSN is configured and no telemetry was sent. Activation still requires a development Sentry project, retention/IP-filtering review, symbol upload, and explicit build configuration. Set `SIGNALWORD_CRASH_REPORTING_ENABLED=YES` and `SIGNALWORD_SENTRY_DSN` only after those prerequisites. A signed-device crash/relaunch and inspection of the received event remain mandatory.

The privacy filter constructs a new event containing only validated crash addresses, image UUIDs, build identity and fixed error text. It excludes contacts, coordinates, capability URLs, secret phrases, arbitrary messages, request data, breadcrumbs and frame variables. Local serializer tests do not prove provider-side IP handling or hosted retention.

Official artifact manifest: https://github.com/getsentry/sentry-apple-binaries/blob/9.29.0/Package.swift
