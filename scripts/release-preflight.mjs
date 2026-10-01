import { localWorkdir } from "./local-fixture.mjs";
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

const projectRoot = new URL('..', import.meta.url).pathname
const findings = []

function command(label, executable, args, { required = true, summarize } = {}) {
  const result = spawnSync(executable, args, { cwd: projectRoot, encoding: 'utf8' })
  const passed = result.status === 0
  const rawDetail = `${result.stdout}${result.stderr}`.trim().split('\n')[0]
  findings.push({ label, passed, required, detail: summarize ? summarize(passed) : rawDetail })
}

function walk(directory) {
  return readdirSync(directory).flatMap((entry) => {
    const path = `${directory}/${entry}`
    return statSync(path).isDirectory() ? walk(path) : [path]
  })
}

function check(label, passed, detail) {
  findings.push({ label, passed, required: true, detail })
}

command('Repository verification', 'npm', ['run', 'verify'])
command('iOS source syntax', 'bash', ['-lc', "find apps/ios/SignalWord -name '*.swift' -print0 | xargs -0 swiftc -parse && swiftc -parse apps/ios/Verification/main.swift"])
command('Full Xcode toolchain', 'xcodebuild', ['-version'])
command('Local Supabase stack', 'npx', ['supabase', '--workdir', localWorkdir, 'status'], {
  summarize: (passed) => passed
    ? 'Local Supabase services are running.'
    : 'Supabase status failed; run npx supabase status locally for diagnostics.',
})
command('Database migration and RLS integration', 'npm', ['run', 'test:db'], {
  summarize: (passed) => passed
    ? 'Database integration and RLS policy tests passed.'
    : 'Database integration tests failed; run npm run test:db locally for diagnostics.',
})

const publicViewerFiles = walk('apps/viewer/src').filter((file) => /\.(ts|tsx)$/.test(file))
const prohibitedDashes = publicViewerFiles.filter((file) => /[—–]/.test(readFileSync(file, 'utf8')))
check('Viewer copy audit', prohibitedDashes.length === 0, prohibitedDashes.length ? `Prohibited dash in ${prohibitedDashes.join(', ')}` : 'No em/en dashes in public viewer copy')

for (const finding of findings) {
  console.log(`${finding.passed ? 'PASS' : 'BLOCKED'} ${finding.label}${finding.detail ? ` - ${finding.detail}` : ''}`)
}

if (findings.some((finding) => finding.required && !finding.passed)) {
  process.exitCode = 1
}
