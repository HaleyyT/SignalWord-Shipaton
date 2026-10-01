import { existsSync, readFileSync } from 'node:fs';

const requiredPaths = [
  'apps/ios/README.md',
  'apps/viewer/src',
  'supabase/migrations',
  'supabase/functions',
  'supabase/tests',
  '.env.example',
];

const forbiddenTrackedPatterns = [
  /sk_(live|test)_[a-z0-9]+/i,
  /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/,
];

for (const path of requiredPaths) {
  if (!existsSync(path)) {
    throw new Error(`Missing required repository path: ${path}`);
  }
}

const exampleEnvironment = readFileSync('.env.example', 'utf8');
if (!exampleEnvironment.includes('VITE_SUPABASE_URL')) {
  throw new Error('.env.example must document the public Supabase URL.');
}

for (const path of ['.env.example', 'README.md']) {
  const content = readFileSync(path, 'utf8');
  if (forbiddenTrackedPatterns.some((pattern) => pattern.test(content))) {
    throw new Error(`Potential secret found in ${path}. Use a placeholder instead.`);
  }
}

console.log('Repository structure and safe configuration examples are valid.');
