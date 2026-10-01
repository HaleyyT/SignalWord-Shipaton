import { existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const strict = process.argv.includes('--strict');

function run(command, args) {
  const result = spawnSync(command, args, { encoding: 'utf8' });
  return {
    ok: result.status === 0,
    output: `${result.stdout ?? ''}${result.stderr ?? ''}`.trim(),
  };
}

function report(label, passed, detail) {
  const status = passed ? 'PASS' : 'BLOCKED';
  console.log(`${status.padEnd(7)} ${label}${detail ? ` — ${detail}` : ''}`);
}

const xcode = run('xcodebuild', ['-version']);
const developerDirectory = run('xcode-select', ['-p']);
const requiredSources = [
  'apps/ios/SignalWord/Services/AppIntents/TriggerAlertIntent.swift',
  'apps/ios/SignalWord/Services/AppIntents/SignalWordAppShortcuts.swift',
  'apps/ios/SignalWord/Core/Security/DeviceCredentialStore.swift',
  'apps/ios/SignalWord/Services/AlertAPI/RemoteAlertAPI.swift',
];
const sourcesPresent = requiredSources.every(existsSync);

console.log('SignalWord Day-1 preflight');
report('iOS source spike', sourcesPresent, sourcesPresent ? 'required files present' : 'a required source file is missing');
report('Full Xcode', xcode.ok, xcode.ok ? xcode.output.replace(/\n/g, '; ') : xcode.output.split('\n')[0]);
report('Active developer directory', developerDirectory.ok, developerDirectory.output);

if (!xcode.ok) {
  console.log('\nNext action: install full Xcode, select it with xcode-select, accept its license, then rerun with --strict.');
}

if (strict && (!sourcesPresent || !xcode.ok)) {
  process.exitCode = 1;
}
