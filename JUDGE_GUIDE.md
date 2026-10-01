# SignalWord evaluator guide

SignalWord is a native iPhone app with a browser-based trusted-contact viewer and Supabase backend. The current Apple submission is version 1.0 (8), with one optional RevenueCat-powered cosmetic purchase. Apple approval and public store availability are pending.

## What to evaluate

1. Consent and preparation: a contact confirms an invitation before receiving alerts and can withdraw later.
2. Rehearsal: TEST is clearly separated from REAL. Recipient acknowledgement and sender resolution are distinct actions.
3. Check-ins: the server owns the deadline; closing the iPhone app does not cancel it.
4. Privacy: Apple recognizes Vocal Shortcut phrases; SignalWord receives an invoked action, not ambient audio. Location is an optional snapshot.
5. Monetization: safety stays free. One non-consumable unlocks Ocean and Lavender accents and a supporter card. Restore purchases and Refresh purchase status are available in Settings → Supporter appearance.

This is not police dispatch, professional monitoring, continuous location tracking or a guarantee of delivery or assistance. SMS is not included.

## Inspect and verify locally

Requirements: Node.js 22/npm 10; Xcode with Swift 6 and an iOS 18-or-later runtime for native checks. Hosted email and purchases additionally require your own provider setup.

```sh
npm ci
npm run verify
swift run --package-path apps/ios SignalWordCoreVerification
npm run test:purchases
```

`npm run verify` checks repository and API contracts, runs Node and viewer tests, type-checks the viewer and builds its production bundle. The Swift verifier exercises the alert core. Supporter tests exercise the purchase model; mocks do not prove a real StoreKit transaction.

To inspect the web interface:

```sh
cp .env.example .env
npm run dev --workspace=@signalword/viewer
```

Use the Vite URL printed in the terminal. Live recipient actions require configured same-origin API proxies and a valid expiring recipient capability; the homepage alone cannot simulate delivery. Component instructions: [viewer](apps/viewer/README.md), [backend](supabase/README.md), [native app](apps/ios/README.md).

## Configure an independent native build

Create an ignored `apps/ios/Config/Judge.xcconfig.local`. Supply client-safe values for:

- `SIGNALWORD_SUPABASE_URL`
- `SIGNALWORD_USER_API_URL` (the project's `/functions/v1/user-api` URL)
- `SIGNALWORD_SUPABASE_PUBLISHABLE_KEY` (public key only)
- `SIGNALWORD_VERIFICATION_URL` (HTTPS origin plus `/onboarding/verify.html`)
- `SIGNALWORD_TURNSTILE_SITE_KEY` (public site key)
- `SIGNALWORD_REVENUECAT_PUBLIC_API_KEY` (your RevenueCat Apple public SDK key)

The supplied build guard intentionally pins SignalWord's backend project. For an independent deployment, change `EXPECTED_REF` in `apps/ios/Config/validate-build-environment.py` to your own project reference and provide matching URLs and a matching public key. Do not disable validation. Set your signing team and owned bundle/App Group identifiers consistently for device installation.

```sh
xcodebuild -project apps/ios/SignalWord.xcodeproj -scheme SignalWord \
  -configuration Debug -sdk iphonesimulator \
  -xcconfig apps/ios/Config/Judge.xcconfig.local CODE_SIGNING_ALLOWED=NO build
```

Deploy the migrations and Edge Functions to your own test Supabase project. `.env.example` lists the server configuration categories. Set privileged credentials through provider secret stores. Configure Turnstile for your verification origin, Resend for a verified sending domain, and the viewer's same-origin proxies. The complete email journey requires these services; source checkout alone is not a hosted deployment.

RevenueCat configuration: product `com.signalword.supporter.appearance`, entitlement `supporter`, offering `supporter`, lifetime package. Use your own StoreKit/RevenueCat testing configuration. Clearly label sandbox, Test Store and simulated transactions; they are not production sales. Never reuse the private Apple reviewer credentials for public judging.

## Controlled end-to-end TEST walkthrough

1. Register a disposable test account using CAPTCHA and its emailed code, or sign into your own existing account with its password.
2. In People, invite an inbox you control. Open the consent email in a browser and confirm participation.
3. With no active alert, choose Send TEST alert. Open the recipient email and explicitly acknowledge it.
4. Return to the app and Refresh status. Resolve using Hold to resolve this alert, or Review and confirm. Acknowledgement alone does not resolve the incident.
5. Start a 15-minute Safety check-in. Wait for Active — confirmed by server, then Check in now and Refresh timer status. Complete or cancel it before the deadline; a missed timer may generate a REAL alert.
6. In Settings → Supporter appearance, demonstrate the purchase, both accents, restoration and status refresh using your configured test store.
7. Finish any alert/timer, then demonstrate Delete account and data with the disposable account.

For optional voice evaluation, save Send TEST Alert in Apple Shortcuts and assign a phrase in iOS Settings → Accessibility → Vocal Shortcuts. Trigger Alert is REAL, not rehearsal. Use consenting controlled recipients for every test.

## Evidence and award eligibility

Apple review screenshots establish submission status only. A public store listing is required for ordinary Shipaton categories unless organizers provide written permission. Next Gen requires an eligible student identity, a public openly licensed repository and a publicly accessible device demo. Private planning, credentials, full review correspondence and internal release evidence are excluded from this repository.
