import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  backendSecrets,
  configurationProblems,
  functions,
  migrationVersions,
  schedules,
  vaultSecrets,
} from "../scripts/release-manifest.mjs";
const config = JSON.parse(
  readFileSync(
    new URL("../config/development.release.json", import.meta.url),
    "utf8",
  ),
);
const inventory = () => ({
  projectRef: config.projectRef,
  backend: backendSecrets,
  vault: vaultSecrets,
  schedules,
  functions,
  migrations: migrationVersions,
  webhook: true,
  journalRetention: true,
  authority: true,
  monitor: true,
  heartbeat: true,
  captcha: true,
});
test("development release identity and old clients are mandatory", () => {
  assert.deepEqual(configurationProblems(config, inventory()), []);
  assert.ok(
    configurationProblems({ ...config, environment: "production" }).includes(
      "DEVELOPMENT_ENVIRONMENT_MISMATCH",
    ),
  );
  assert.ok(
    configurationProblems({ ...config, apiContractVersions: [2] }).includes(
      "OLD_CLIENT_COMPATIBILITY_MISSING",
    ),
  );
  assert.ok(
    configurationProblems({ ...config, features: { sms: true } }).includes(
      "UNSUPPORTED_PILOT_CONFIGURATION",
    ),
  );
});
test("preflight reports missing names and service evidence without secret values", () => {
  const missing = {
    ...inventory(),
    backend: [],
    vault: [],
    schedules: [],
    authority: false,
    projectRef: "wrong",
  };
  const problems = configurationProblems(config, missing);
  assert.ok(problems.includes("MISSING_BACKEND:RESEND_WEBHOOK_SECRET"));
  assert.ok(problems.includes("UNVERIFIED_AUTHORITY"));
  assert.ok(problems.includes("INVENTORY_PROJECT_MISMATCH"));
  assert.ok(problems.every((p) => !p.includes("https://")));
});
