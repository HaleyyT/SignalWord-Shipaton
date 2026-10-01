import { acquireLocalFixtureLock, localWorkdir } from "./local-fixture.mjs";
acquireLocalFixtureLock();
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const root = new URL('..', import.meta.url).pathname;
const testsDirectory = `${root}/supabase/tests`;
const supabase = `${root}/node_modules/.bin/supabase`;

function run(executable, args, options = {}) {
  return spawnSync(executable, args, {
    cwd: root,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    ...options,
  });
}

function output(result) {
  process.stdout.write(result.stdout ?? '');
  process.stderr.write(result.stderr ?? '');
}

if (!existsSync(supabase)) {
  console.error('Supabase CLI is not installed. Run npm install first.');
  process.exit(1);
}

const standard = run(supabase, ['--workdir', localWorkdir, 'test', 'db', testsDirectory]);
if (standard.status === 0) {
  output(standard);
  process.exit(0);
}

const standardFailure = `${standard.stdout ?? ''}\n${standard.stderr ?? ''}`;
const dockerDesktopMountDenied = /error while creating mount source path[\s\S]*operation not permitted/i
  .test(standardFailure);
if (!dockerDesktopMountDenied) {
  output(standard);
  process.exit(standard.status ?? 1);
}

// Docker Desktop on macOS may run the database but refuse to bind-mount a
// Desktop-hosted test directory. Copy the exact committed suites into that
// project's local database container and run them there. CI and all other
// environments continue to use `supabase test db` above.
const config = readFileSync(`${localWorkdir}/supabase/config.toml`, 'utf8');
const projectID = /^project_id\s*=\s*"([A-Za-z0-9_-]+)"/m.exec(config)?.[1];
if (!projectID) {
  console.error('Could not resolve a safe Supabase project_id for the Docker fallback.');
  process.exit(1);
}

const container = `supabase_db_${projectID}`;
const containerTests = `/tmp/signalword-pgtap-${projectID}`;
const suites = readdirSync(testsDirectory)
  .filter((name) => name.endsWith('.test.sql'))
  .sort();
if (suites.length === 0) {
  console.error('No pgTAP suites were found.');
  process.exit(1);
}

console.log('Docker Desktop blocked the test bind mount; using the local-container pgTAP fallback.');

for (const [executable, args] of [
  ['docker', ['exec', container, 'mkdir', '-p', containerTests]],
  ['docker', ['cp', `${testsDirectory}/.`, `${container}:${containerTests}/`]],
  ['docker', ['exec', container, 'psql', '-X', '-v', 'ON_ERROR_STOP=1', '--username', 'postgres',
    '--dbname', 'postgres', '-c', 'create extension if not exists pgtap with schema extensions']],
]) {
  const result = run(executable, args);
  if (result.status !== 0) {
    output(result);
    process.exit(result.status ?? 1);
  }
}

let assertions = 0;
for (const suite of suites) {
  const result = run('docker', [
    'exec', '--env', 'PGOPTIONS=-c search_path=public,extensions', container,
    'psql', '-X', '-v', 'ON_ERROR_STOP=1', '--username', 'postgres', '--dbname', 'postgres',
    '-f', `${containerTests}/${suite}`,
  ]);
  const combined = `${result.stdout ?? ''}\n${result.stderr ?? ''}`;
  if (result.status !== 0 || /^\s*not ok\b/im.test(combined)) {
    console.error(`BLOCKED ${suite}`);
    output(result);
    process.exit(result.status || 1);
  }
  const count = (combined.match(/^\s*ok \d+ -/gm) ?? []).length;
  assertions += count;
  console.log(`PASS ${suite} (${count} assertions)`);
}

console.log(`Database integration passed: ${assertions} pgTAP assertions across ${suites.length} suites.`);
