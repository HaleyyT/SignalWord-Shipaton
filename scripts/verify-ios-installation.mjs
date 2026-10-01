import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
const configuration = JSON.parse(
  readFileSync(new URL("../config/development.release.json", import.meta.url)),
);
// Provisioning profiles contain plist dates and binary certificates. plutil's
// JSON conversion rejects these types, so normalize them without logging data.
export function decodePlist(input) {
  return JSON.parse(execFileSync("python3", ["-c", `
import base64, datetime, json, plistlib, sys
def encode(value):
    if isinstance(value, datetime.datetime):
        return value.replace(tzinfo=datetime.timezone.utc).isoformat()
    if isinstance(value, bytes):
        return base64.b64encode(value).decode("ascii")
    raise TypeError("Unsupported plist value")
json.dump(plistlib.loads(sys.stdin.buffer.read()), sys.stdout, default=encode)
`], { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }));
}
export function installationProblems(
  info,
  entitlements,
  profile,
  team,
  now = Date.now(),
) {
  const errors = [];
  if (!info.UILaunchScreen || typeof info.UILaunchScreen !== "object" || Array.isArray(info.UILaunchScreen)) {
    errors.push("MODERN_LAUNCH_SCREEN_REQUIRED");
  }
  if (!/^[A-Z0-9]{10}$/.test(team ?? "")) {
    errors.push("OWNED_PAID_TEAM_ID_REQUIRED");
  }
  if (info.CFBundleIdentifier !== configuration.app.bundleId) {
    errors.push("BUNDLE_MISMATCH");
  }
  if (
    String(info.CFBundleVersion) !== String(configuration.app.build) ||
    info.CFBundleShortVersionString !== configuration.app.version
  ) errors.push("BUILD_MISMATCH");
  if (
    info.SignalWordAppGroupIdentifier !== configuration.app.appGroup ||
    !entitlements["com.apple.security.application-groups"]?.includes(
      configuration.app.appGroup,
    )
  ) errors.push("APP_GROUP_MISMATCH");
  if (
    entitlements["com.apple.developer.team-identifier"] !== team ||
    !profile.TeamIdentifier?.includes(team)
  ) errors.push("TEAM_MISMATCH");
  if (
    entitlements["application-identifier"] !==
      `${team}.${configuration.app.bundleId}`
  ) errors.push("SIGNED_APPLICATION_MISMATCH");
  if (
    !profile.Entitlements?.["com.apple.security.application-groups"]?.includes(
      configuration.app.appGroup,
    )
  ) errors.push("PROFILE_APP_GROUP_MISSING");
  if (
    !Number.isFinite(Date.parse(profile.ExpirationDate)) ||
    Date.parse(profile.ExpirationDate) <= now
  ) errors.push("PROFILE_EXPIRED");
  if (
    !Array.isArray(profile.ProvisionedDevices) ||
    profile.ProvisionedDevices.length === 0
  ) errors.push("DEVELOPMENT_DEVICE_PROFILE_REQUIRED");
  const base = `https://${configuration.projectRef}.supabase.co`;
  for (
    const [key, value] of Object.entries({
      SignalWordSupabaseURL: base,
      SignalWordUserAPIURL: `${base}/functions/v1/user-api`,
      SignalWordVerificationURL:
        `${configuration.viewerOrigin}/onboarding/verify.html`,
      SignalWordTurnstileSiteKey: configuration.turnstileSiteKey,
    })
  ) if (info[key] !== value) errors.push(`CONFIGURATION_MISMATCH:${key}`);
  const key = info.SignalWordSupabasePublishableKey ?? "";
  let publicKey = key.startsWith("sb_publishable_");
  try {
    publicKey ||=
      JSON.parse(Buffer.from(key.split(".")[1], "base64url")).role === "anon";
  } catch {}
  if (!publicKey) errors.push("PUBLISHABLE_CLIENT_KEY_REQUIRED");
  if (
    !["NO", "false", false, undefined, ""].includes(
      info.SignalWordCrashReportingEnabled,
    )
  ) errors.push("UNVERIFIED_CRASH_REPORTING_ENABLED");
  return errors;
}
if (
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const app = resolve(process.argv[2] ?? "");
  if (!app.endsWith(".app")) throw Error("SIGNED_APP_PATH_REQUIRED");
  // Inspecting entitlements alone does not verify the code signature.
  execFileSync("codesign", ["--verify", "--deep", "--strict", app], { stdio: "ignore" });
  const plist = decodePlist;
  const info = plist(readFileSync(resolve(app, "Info.plist")));
  const entitlements = plist(
    execFileSync("codesign", ["-d", "--entitlements", ":-", app], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    }),
  );
  const profile = plist(
    execFileSync("security", [
      "cms",
      "-D",
      "-i",
      resolve(app, "embedded.mobileprovision"),
    ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }),
  );
  const problems = installationProblems(
    info,
    entitlements,
    profile,
    process.env.SIGNALWORD_EXPECTED_TEAM,
  );
  console.log(
    JSON.stringify({
      passed: problems.length === 0,
      problems,
      bundleId: info.CFBundleIdentifier,
      version: info.CFBundleShortVersionString,
      build: info.CFBundleVersion,
    }),
  );
  if (problems.length) process.exitCode = 1;
}
