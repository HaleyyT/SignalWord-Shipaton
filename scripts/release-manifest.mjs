import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { resolve } from "node:path";

export const functions = [
  "user-api",
  "public-event",
  "contact-confirm",
  "deletion-status",
  "dispatch-deliveries",
  "resend-webhook",
  "operational-health",
];
export const migrationVersions = readdirSync(
  fileURLToPath(new URL("../supabase/migrations/", import.meta.url)),
).filter((p) => /^[0-9]+_.+\.sql$/.test(p)).sort();
export const backendSecrets = [
  "APP_ENV",
  "DELIVERY_PROVIDER",
  "RESEND_API_KEY",
  "RESEND_FROM_EMAIL",
  "RESEND_WEBHOOK_SECRET",
  "PUBLIC_VIEWER_BASE_URL",
  "PUBLIC_CONFIRMATION_BASE_URL",
  "DISPATCH_SECRET",
  "DELIVERY_PAYLOAD_KEY",
  "DELIVERY_PAYLOAD_KEY_VERSION",
  "DESTINATION_ENCRYPTION_KEY",
  "DESTINATION_FINGERPRINT_KEY",
  "DESTINATION_KEY_VERSION",
  "SAFETY_CONTROL_URL",
  "SAFETY_CONTROL_WRITER",
  "MONITOR_SECRET",
];
export const vaultSecrets = [
  "signalword_backend_url",
  "signalword_dispatch_secret",
  "signalword_control_url",
  "signalword_control_reader",
];
export const schedules = [
  "signalword-dispatch-sweep",
  "signalword-delivery-lease-recovery",
  "signalword-hourly-retention",
  "signalword-check-in-expiry",
  "signalword-check-in-retention",
];

export function configurationProblems(config, inventory) {
  const problems = [];
  if (
    config?.environment !== "development" ||
    config.projectRef !== "voepalyamwgenceawdvl"
  ) problems.push("DEVELOPMENT_ENVIRONMENT_MISMATCH");
  if (config?.viewerOrigin !== "https://www.signalword.app") {
    problems.push("VIEWER_ORIGIN_MISMATCH");
  }
  if (
    config?.deliveryProvider !== "resend" || config?.features?.sms !== false ||
    config?.features?.professionalMonitoring !== false
  ) problems.push("UNSUPPORTED_PILOT_CONFIGURATION");
  if (!/^[A-Za-z0-9_-]{10,100}$/.test(config?.turnstileSiteKey ?? "")) {
    problems.push("TURNSTILE_SITE_KEY_MISSING");
  }
  if (
    !config?.apiContractVersions?.includes(1) ||
    !config?.apiContractVersions?.includes(2)
  ) problems.push("OLD_CLIENT_COMPATIBILITY_MISSING");
  if (inventory) {
    if (inventory.projectRef !== config.projectRef) {
      problems.push("INVENTORY_PROJECT_MISMATCH");
    }
    for (
      const [kind, names] of [["backend", backendSecrets], [
        "vault",
        vaultSecrets,
      ], ["schedules", schedules]]
    ) {
      for (const name of names) {
        if (!inventory[kind]?.includes(name)) {
          problems.push(`MISSING_${kind.toUpperCase()}:${name}`);
        }
      }
    }
    for (
      const [kind, names] of [["functions", functions], [
        "migrations",
        migrationVersions,
      ]]
    ) {
      for (const name of names) {
        if (!inventory[kind]?.includes(name)) {
          problems.push(`MISSING_${kind.toUpperCase()}:${name}`);
        }
      }
    }
    for (
      const name of [
        "authority",
        "monitor",
        "heartbeat",
        "captcha",
        "webhook",
        "journalRetention",
      ]
    ) {
      if (inventory[name] !== true) {
        problems.push(`UNVERIFIED_${name.toUpperCase()}`);
      }
    }
  }
  return problems;
}
export function releaseManifest(root, config, { allowDirty = false } = {}) {
  const git = (args) =>
    execFileSync("git", args, { cwd: root, encoding: "utf8" }).trim();
  const dirty = git(["status", "--porcelain"]).length > 0;
  if (dirty && !allowDirty) throw Error("CANDIDATE_HAS_UNCOMMITTED_CHANGES");
  const problems = configurationProblems(config);
  if (problems.length) throw Error(problems.join("\n"));
  const paths = git(["ls-files", "--cached", "--others", "--exclude-standard"])
    .split("\n").filter((p) =>
      /^(apps\/ios\/|apps\/viewer\/|supabase\/|infrastructure\/|contracts\/|config\/|scripts\/|package(?:-lock)?\.json$)/
        .test(p) &&
      !/(^|\/)(node_modules|dist|\.build|build|\.swiftpm|\.temp|xcuserdata)\//
        .test(p) &&
      /\.(swift|pbxproj|xcscheme|entitlements|plist|xcprivacy|png|svg|ts|tsx|mjs|css|html|sql|json|jsonc|toml|sh|resolved)$/
        .test(p)
    );
  const files = Object.fromEntries(
    [...new Set(paths)].sort().map(
      (p) => [
        p,
        createHash("sha256").update(readFileSync(resolve(root, p))).digest(
          "hex",
        ),
      ],
    ),
  );
  return {
    schemaVersion: 1,
    commit: git(["rev-parse", "HEAD"]),
    dirty,
    configuration: config,
    files,
    migrations: Object.keys(files).filter((p) =>
      p.startsWith("supabase/migrations/")
    ),
    functions,
    requiredNames: { backend: backendSecrets, vault: vaultSecrets, schedules },
    apiOrigin: `https://${config.projectRef}.supabase.co/functions/v1/user-api`,
    verificationURL: `${config.viewerOrigin}/onboarding/verify.html`,
  };
}
if (
  process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  const root = fileURLToPath(new URL("..", import.meta.url));
  const config = JSON.parse(
    readFileSync(resolve(root, "config/development.release.json"), "utf8"),
  );
  const inventoryPath = process.env.SIGNALWORD_RELEASE_INVENTORY;
  const problems = configurationProblems(
    config,
    inventoryPath ? JSON.parse(readFileSync(inventoryPath, "utf8")) : undefined,
  );
  if (problems.length) throw Error(problems.join("\n"));
  if (process.argv.includes("--check-environment") && !inventoryPath) {
    throw Error("SECRET_NAME_AND_SERVICE_INVENTORY_REQUIRED");
  }
  console.log(
    JSON.stringify(
      releaseManifest(root, config, {
        allowDirty: process.argv.includes("--allow-dirty"),
      }),
      null,
      2,
    ),
  );
}
