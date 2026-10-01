import test from 'node:test';
import assert from 'node:assert/strict';
import { checkHostedViewer } from '../scripts/hosted-preflight.mjs';
import { proxyContactConfirmation } from '../apps/viewer/api/v1/contacts/confirm/[token].mjs';

const security = { 'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff',
  'strict-transport-security': 'max-age=31536000', 'cache-control': 'no-store',
  'content-security-policy': "frame-ancestors 'none'" };

test('hosted preflight checks both methods and never needs a real capability', async () => {
  const calls = [];
  const results = await checkHostedViewer('https://viewer.example', async (url, init) => {
    calls.push({ url, init });
    if (url.pathname.startsWith('/events/') || url.pathname.startsWith('/confirm/')) {
      return new Response('<html></html>', { headers: { ...security, 'content-type': 'text/html' } });
    }
    if (url.pathname.startsWith('/api/v1/contacts/confirm/')) {
      const result = await proxyContactConfirmation({
        token: url.pathname.split('/').at(-1), upstreamOrigin: 'https://backend.example',
        action: init.headers['X-SignalWord-Action'] ?? 'confirm',
        fetchImpl: async () => Response.json({}, { status: 404 }),
      });
      const headers = new Headers(security);
      for (const [name, value] of Object.entries(result.headers)) headers.set(name, value);
      return Response.json(result.body, { status: result.status, headers });
    }
    return Response.json({ error: { code: 'NOT_FOUND' } }, { status: 404, headers: security });
  });
  assert.equal(results.length, 6);
  assert.ok(results.every((result) => result.passed));
  assert.equal(calls[3].init.method, 'POST');
  assert.equal(calls[3].init.headers['X-SignalWord-Action'], 'acknowledge');
  assert.equal(calls[5].init.headers['X-SignalWord-Action'], 'withdraw');
  assert.equal(calls[0].init.redirect, 'error');
  assert.match(calls[0].url.pathname, /^\/events\/[A-Za-z0-9_-]{43}$/);
});

test('unavailable status alone does not satisfy the contact response contract', async () => {
  for (const body of [{}, { confirmed: true, unavailable: true }, { error: { code: 'NOT_FOUND' } }]) {
    const results = await checkHostedViewer('https://viewer.example', async () =>
      Response.json(body, { status: 410, headers: security }));
    assert.ok(results.slice(4).every(result => !result.passed));
  }
});

test('SPA fallthrough and missing privacy headers cannot pass hosted preflight', async () => {
  const results = await checkHostedViewer('https://viewer.example', async () => new Response('<html>SPA</html>'));
  assert.ok(results.every((result) => !result.passed));
});

test('network errors redact capability-bearing URLs', async () => {
  const results = await checkHostedViewer('https://viewer.example', async (url) => { throw new Error(url.toString()); });
  assert.ok(results.every((result) => !result.passed));
  assert.ok(!JSON.stringify(results).includes('https://'));
  await assert.rejects(checkHostedViewer('http://viewer.example'), /HTTPS origin/);
});
