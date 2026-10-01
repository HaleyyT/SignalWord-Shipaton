import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';

test('repository documents the supported environments', () => {
  const readme = readFileSync('README.md', 'utf8');
  assert.match(readme, /development\/test/i);
  assert.match(readme, /production/i);
});

test('dangerous local configuration is ignored', () => {
  const gitignore = readFileSync('.gitignore', 'utf8');
  assert.match(gitignore, /^\.env$/m);
  assert.match(gitignore, /^\*\.p8$/m);
});

test('planned application boundaries exist', () => {
  for (const path of ['apps/ios', 'apps/viewer', 'supabase/migrations', 'supabase/functions']) {
    assert.ok(existsSync(path), `${path} should exist`);
  }
});

test('locked intent is deliberately narrow and silent', () => {
  const intent = readFileSync('apps/ios/SignalWord/Services/AppIntents/TriggerAlertIntent.swift', 'utf8');
  const credentials = readFileSync('apps/ios/SignalWord/Core/Security/DeviceCredentialStore.swift', 'utf8');
  assert.match(intent, /authenticationPolicy.*\.alwaysAllowed/);
  assert.match(intent, /openAppWhenRun = false/);
  assert.doesNotMatch(intent, /IntentDialog/);
  assert.match(credentials, /kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly/);
});

test('day-one preflight reports the Xcode gate without masking blockers', () => {
  const output = execFileSync('node', ['scripts/day1-preflight.mjs'], { encoding: 'utf8' });
  assert.match(output, /SignalWord Day-1 preflight/);
  assert.match(output, /iOS source spike/);
  assert.match(output, /Full Xcode/);
});

test('release evidence template preserves the required reliability and abuse checks', { skip: !existsSync('docs/RELEASE_EVIDENCE.md') }, () => {
  const evidence = readFileSync('docs/RELEASE_EVIDENCE.md', 'utf8');
  assert.match(evidence, /Ten-run end-to-end log/);
  assert.match(evidence, /User A cannot read User B data/);
  assert.match(evidence, /Delete-data flow revokes prior token/);
});

test('Day-7 materials prohibit staged safety claims and retain evidence gates', { skip: !existsSync('docs/DEMO_PRODUCTION_RUNBOOK.md') }, () => {
  const demoRunbook = readFileSync('docs/DEMO_PRODUCTION_RUNBOOK.md', 'utf8');
  const packet = readFileSync('docs/SUBMISSION_PACKET_DRAFT.md', 'utf8');
  assert.match(demoRunbook, /must never stage a delivery/i);
  assert.match(demoRunbook, /release:preflight/);
  assert.match(packet, /not a submitted Devpost form/i);
  assert.match(packet, /Evidence still required/i);
});

test('release preflight summarizes Supabase health without echoing status credentials', () => {
  const preflight = readFileSync('scripts/release-preflight.mjs', 'utf8');
  assert.match(preflight, /Local Supabase services are running/);
  assert.match(preflight, /Database migration and RLS integration/);
  assert.match(preflight, /npm run test:db/);
  assert.match(preflight, /Supabase status failed; run npx supabase status locally for diagnostics/);
  assert.doesNotMatch(preflight, /PUBLISHABLE_KEY/);
  assert.doesNotMatch(preflight, /SERVICE_ROLE_KEY/);
});

test('database policy integration tests are committed and exercised in CI', () => {
  const policyTest = readFileSync('supabase/tests/rls_policies.test.sql', 'utf8');
  const ci = readFileSync('.github/workflows/ci.yml', 'utf8');
  assert.match(policyTest, /select plan\(56\)/);
  assert.match(policyTest, /anonymous clients cannot query alert events/);
  assert.match(policyTest, /user B cannot see user A events/);
  assert.match(policyTest, /an event cannot reference another user contact/);
  assert.match(policyTest, /profile deletion removes viewer tokens/);
  assert.match(ci, /npm run test:db/);
});

test('database runner keeps the standard path and narrowly handles the Docker Desktop mount failure', () => {
  const runner = readFileSync('scripts/test-database.mjs', 'utf8');
  assert.match(runner, /'test', 'db', testsDirectory/);
  assert.match(runner, /error while creating mount source path/);
  assert.match(runner, /operation not permitted/);
  assert.match(runner, /PGOPTIONS=-c search_path=public,extensions/);
  assert.match(runner, /not ok/);
  assert.doesNotMatch(runner, /SERVICE_ROLE_KEY|SECRET_KEY|ANON_KEY/);
});

test('CI type-checks every Edge Function and blocks high-severity runtime dependencies', () => {
  const ci = readFileSync('.github/workflows/ci.yml', 'utf8');
  for (const entrypoint of [
    'user-api/index.ts', 'public-event/index.ts', 'contact-confirm/index.ts',
    'dispatch-deliveries/index.ts', 'resend-webhook/index.ts',
  ]) {
    assert.match(ci, new RegExp(entrypoint.replace('.', '\\.')));
  }
  assert.match(ci, /deno check/);
  assert.match(ci, /npm audit --omit=dev --audit-level=high/);
});

test('Day-8 audit fails closed when required production evidence is absent', { skip: !existsSync('docs/DAY_8_RELEASE_AUDIT.md') }, () => {
  const audit = readFileSync('docs/DAY_8_RELEASE_AUDIT.md', 'utf8');
  assert.match(audit, /not accepted for production release or Shipaton submission yet/i);
  assert.match(audit, /Current repository implementation quality: 88\/100/);
  assert.match(audit, /Current production\/Shipaton release readiness: 64\/100/);
  assert.match(audit, /95\/100 acceptance: not yet earned/i);
  assert.match(audit, /RevenueCat `plus` entitlement/);
  assert.match(audit, /50 phrase trials/);
  assert.match(audit, /must not be described as end-to-end working/i);
});
