import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'

const trackedFiles = execFileSync('git', ['ls-files', '-z'], { encoding: 'utf8' })
  .split('\0')
  .filter(Boolean)

const publicViewerFiles = trackedFiles.filter((path) =>
  path === 'apps/viewer/index.html' ||
  path.startsWith('apps/viewer/src/') ||
  path.startsWith('apps/viewer/public/') ||
  path.startsWith('contracts/v1/')
)

const forbiddenPublicPatterns = [
  { name: 'browser storage', pattern: /\b(?:localStorage|sessionStorage|document\.cookie)\b/ },
  { name: 'browser logging', pattern: /\bconsole\.(?:log|info|debug|warn|error)\b/ },
  { name: 'server credential reference', pattern: /\b(?:service[_-]?role|service[_-]?key|secret[_-]?key|SUPABASE_SERVICE)\b/i },
]

const violations = []
for (const path of publicViewerFiles) {
  const content = readFileSync(path, 'utf8')
  for (const { name, pattern } of forbiddenPublicPatterns) {
    if (pattern.test(content)) violations.push(`${name} in ${path}`)
  }
}

const viewerDocument = readFileSync('apps/viewer/index.html', 'utf8')
const viewerBuildConfiguration = readFileSync('apps/viewer/vite.config.ts', 'utf8')
if (!/name="referrer" content="no-referrer"/.test(viewerDocument)) {
  violations.push('missing no-referrer policy in apps/viewer/index.html')
}
if (!/productionSecurityHeaders/.test(viewerBuildConfiguration) ||
  !/default-src 'self'/.test(viewerBuildConfiguration) ||
  !/connect-src 'self'/.test(viewerBuildConfiguration) ||
  !/object-src 'none'/.test(viewerBuildConfiguration)) {
  violations.push('missing restrictive production content security policy')
}

if (violations.length) {
  throw new Error(`Public viewer security audit failed: ${violations.join('; ')}`)
}

console.log('Public viewer security boundaries are valid.')
