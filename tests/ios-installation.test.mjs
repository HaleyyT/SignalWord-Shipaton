import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { decodePlist, installationProblems } from "../scripts/verify-ios-installation.mjs";
const team = "ABC123DE45", group = "group.com.signalword.shared";
const info = {
  UILaunchScreen: {},
  CFBundleIdentifier: "com.signalword.app",
  CFBundleVersion: "4",
  CFBundleShortVersionString: "1.0",
  SignalWordAppGroupIdentifier: group,
  SignalWordSupabaseURL: "https://voepalyamwgenceawdvl.supabase.co",
  SignalWordUserAPIURL:
    "https://voepalyamwgenceawdvl.supabase.co/functions/v1/user-api",
  SignalWordVerificationURL:
    "https://www.signalword.app/onboarding/verify.html",
  SignalWordTurnstileSiteKey: "0x4AAAAAAFFb3ETKlwBxFCNF",
  SignalWordSupabasePublishableKey: "sb_publishable_fixture",
  SignalWordCrashReportingEnabled: "NO",
};
const entitlements = {
  "com.apple.security.application-groups": [group],
  "com.apple.developer.team-identifier": team,
  "application-identifier": team + ".com.signalword.app",
};
const profile = {
  TeamIdentifier: [team],
  Entitlements: { "com.apple.security.application-groups": [group] },
  ExpirationDate: "2030-01-01",
  ProvisionedDevices: ["fixture-device"],
};
test("candidate metadata matches only the owned team and development configuration", () => {
  assert.deepEqual(installationProblems(info, entitlements, profile, team), []);
  assert.ok(
    installationProblems(info, entitlements, profile, undefined).includes(
      "OWNED_PAID_TEAM_ID_REQUIRED",
    ),
  );
  assert.ok(
    installationProblems(
      { ...info, SignalWordUserAPIURL: "https://production.invalid" },
      entitlements,
      profile,
      team,
    ).includes("CONFIGURATION_MISMATCH:SignalWordUserAPIURL"),
  );
});
test("unsafe credentials, wrong groups, stale builds and expired profiles block installation", () => {
  const errors = installationProblems(
    {
      ...info,
      CFBundleVersion: "1",
      SignalWordSupabasePublishableKey: "sb_secret_fixture",
      SignalWordCrashReportingEnabled: "YES",
    },
    { ...entitlements, "com.apple.security.application-groups": [] },
    { ...profile, ExpirationDate: "2000-01-01" },
    team,
  );
  for (
    const code of [
      "BUILD_MISMATCH",
      "PUBLISHABLE_CLIENT_KEY_REQUIRED",
      "UNVERIFIED_CRASH_REPORTING_ENABLED",
      "APP_GROUP_MISMATCH",
      "PROFILE_EXPIRED",
    ]
  ) assert.ok(errors.includes(code));
});


test("real profile plist dates and certificate data survive decoding", () => {
  const parsed = decodePlist(Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>ExpirationDate</key><date>2027-09-29T00:00:00Z</date>
<key>DeveloperCertificates</key><array><data>AQID</data></array>
<key>Entitlements</key><dict><key>get-task-allow</key><true/></dict>
</dict></plist>`));
  assert.equal(Date.parse(parsed.ExpirationDate), Date.parse("2027-09-29T00:00:00Z"));
  assert.deepEqual(parsed.DeveloperCertificates, ["AQID"]);
  assert.equal(parsed.Entitlements["get-task-allow"], true);
  assert.throws(() => decodePlist(Buffer.from("invalid plist")));
});


test("both app configurations package the complete client settings plist", () => {
  const source = decodePlist(readFileSync(new URL("../apps/ios/Config/SignalWord-Info.plist", import.meta.url)));
  const expected = {
    UILaunchScreen: { UIColorName: "LaunchBackground" },
    SignalWordAppGroupIdentifier: group,
    SignalWordCrashReportingEnabled: "$(SIGNALWORD_CRASH_REPORTING_ENABLED)",
    SignalWordRevenueCatAPIKey: "$(SIGNALWORD_REVENUECAT_PUBLIC_API_KEY)",
    SignalWordSentryDSN: "$(SIGNALWORD_SENTRY_DSN)",
    SignalWordSupabasePublishableKey: "$(SIGNALWORD_SUPABASE_PUBLISHABLE_KEY)",
    SignalWordSupabaseURL: "$(SIGNALWORD_SUPABASE_URL)",
    SignalWordTurnstileSiteKey: "$(SIGNALWORD_TURNSTILE_SITE_KEY)",
    SignalWordUserAPIURL: "$(SIGNALWORD_USER_API_URL)",
    SignalWordVerificationURL: "$(SIGNALWORD_VERIFICATION_URL)",
  };
  assert.deepEqual(source, expected);
  const project = readFileSync(new URL("../apps/ios/SignalWord.xcodeproj/project.pbxproj", import.meta.url), "utf8");
  assert.equal(project.split("INFOPLIST_FILE = Config/SignalWord-Info.plist;").length - 1, 2);
});


test("the signed artifact must declare its launch screen", () => {
  const { UILaunchScreen, ...legacy } = info;
  assert.ok(installationProblems(legacy, entitlements, profile, team).includes("MODERN_LAUNCH_SCREEN_REQUIRED"));
  assert.ok(installationProblems({ ...info, UILaunchScreen: "" }, entitlements, profile, team).includes("MODERN_LAUNCH_SCREEN_REQUIRED"));
});
