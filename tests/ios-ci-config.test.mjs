import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('offline CI configuration exposes sign-in without live credentials', () => {
  const directory = mkdtempSync(join(tmpdir(), 'signalword-ci-config-'));
  try {
    const environmentFile = join(directory, 'github-env');
    execFileSync('bash', ['scripts/prepare-ios-ci-config.sh'], {
      env: { ...process.env, GITHUB_ACTIONS: 'true', RUNNER_TEMP: directory, GITHUB_ENV: environmentFile },
    });
    const path = join(directory, 'SignalWord-CI.xcconfig');
    const values = Object.fromEntries(readFileSync(path, 'utf8').split('\n')
      .filter(line => line.startsWith('SIGNALWORD_'))
      .map(line => {
        const [name, value] = line.split(' = ');
        return [name, value.replaceAll('$()', '')];
      }));
    const verification = new URL(values.SIGNALWORD_VERIFICATION_URL);
    assert.equal(verification.protocol, 'https:');
    assert.equal(verification.pathname, '/onboarding/verify.html');
    assert.equal(verification.search, '');
    assert.equal(verification.hash, '');
    assert.match(values.SIGNALWORD_TURNSTILE_SITE_KEY, /^[A-Za-z0-9_-]{10,100}$/);
    assert.match(values.SIGNALWORD_TURNSTILE_SITE_KEY, /NOT_A_LIVE/);
    assert.match(values.SIGNALWORD_SUPABASE_PUBLISHABLE_KEY, /NOT_A_LIVE/);
    execFileSync('python3', ['apps/ios/Config/validate-build-environment.py'], {
      env: { ...process.env, ...values },
    });
    assert.equal(readFileSync(environmentFile, 'utf8'), `SIGNALWORD_XCCONFIG=${path}\n`);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
