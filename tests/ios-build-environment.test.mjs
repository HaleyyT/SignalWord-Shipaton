import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const script = 'apps/ios/Config/validate-build-environment.py';
const origin = 'https://voepalyamwgenceawdvl.supabase.co';
const key = 'sb_publishable_' + 'a'.repeat(24);
const valid = { SIGNALWORD_SUPABASE_URL: origin, SIGNALWORD_USER_API_URL: origin + '/functions/v1/user-api', SIGNALWORD_SUPABASE_PUBLISHABLE_KEY: key };
function run(values, plist) {
  return spawnSync('/usr/bin/python3', [script, ...(plist ? ['--plist', plist] : [])], { env: { PATH: process.env.PATH, ...values }, encoding: 'utf8' });
}
test('Debug and Release require every backend setting', () => {
  for (const CONFIGURATION of ['Debug', 'Release']) {
    assert.equal(run({ ...valid, CONFIGURATION }).status, 0);
    for (const name of Object.keys(valid)) {
      const result = run({ ...valid, CONFIGURATION, [name]: '' });
      assert.equal(result.status, 1);
      assert.match(result.stderr, /error: SignalWord build configuration/);
      assert.ok(!result.stderr.includes(key));
    }
  }
});
test('reject localhost, placeholder and mismatched project endpoints', () => {
  for (const url of ['http://localhost:54321', 'https://example.invalid', 'https://anotherproject.supabase.co', origin + '/', origin + '?x=1']) {
    assert.equal(run({ ...valid, SIGNALWORD_SUPABASE_URL: url }).status, 1);
  }
  assert.equal(run({ ...valid, SIGNALWORD_USER_API_URL: 'https://anotherproject.supabase.co/functions/v1/user-api' }).status, 1);
});
test('reject unresolved, placeholder and secret keys without logging them', () => {
  for (const value of ['$(KEY)', 'placeholder', 'sb_secret_abc', ' ' + key]) {
    assert.equal(run({ ...valid, SIGNALWORD_SUPABASE_PUBLISHABLE_KEY: value }).status, 1);
  }
});
test('legacy key must identify the intended project and anon role', () => {
  const jwt = (role, ref) => 'eyJhbGciOiJIUzI1NiJ9.' + Buffer.from(JSON.stringify({ role, ref })).toString('base64url') + '.signature';
  assert.equal(run({ ...valid, SIGNALWORD_SUPABASE_PUBLISHABLE_KEY: jwt('anon', 'voepalyamwgenceawdvl') }).status, 0);
  for (const [role, ref] of [['service_role', 'voepalyamwgenceawdvl'], ['anon', 'different']]) {
    assert.equal(run({ ...valid, SIGNALWORD_SUPABASE_PUBLISHABLE_KEY: jwt(role, ref) }).status, 1);
  }
});
test('processed plist must exist and exactly match intended values', () => {
  const dir = mkdtempSync(join(tmpdir(), 'signalword-config-'));
  const path = join(dir, 'Info.plist');
  const plist = (bundledKey) => `<?xml version="1.0"?><plist version="1.0"><dict><key>SignalWordSupabaseURL</key><string>${origin}</string><key>SignalWordUserAPIURL</key><string>${origin}/functions/v1/user-api</string><key>SignalWordSupabasePublishableKey</key><string>${bundledKey}</string></dict></plist>`;
  try {
    assert.equal(run(valid, path).status, 1);
    writeFileSync(path, plist(key));
    assert.equal(run(valid, path).status, 0);
    writeFileSync(path, plist('wrong-public-key'));
    assert.equal(run(valid, path).status, 1);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
