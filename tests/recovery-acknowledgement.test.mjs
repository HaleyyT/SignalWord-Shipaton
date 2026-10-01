import test from 'node:test';
import assert from 'node:assert/strict';
import { createPublicEventHandler } from '../supabase/functions/public-event/index.ts';
import { proxyPublicEvent } from '../apps/viewer/api/v1/public/events/[token].mjs';
import { wakeDispatch } from '../supabase/functions/_shared/dispatch-wakeup.ts';

const token = 'a'.repeat(43);
test('acknowledgement is explicit, token-scoped and never performed by a GET', async () => {
  let acknowledgements = 0;
  const handler = createPublicEventHandler({
    backend: { publicEvent: async () => null, acknowledge: async hash => { assert.equal(hash.length, 64); acknowledgements++; return true; } },
    logger: { write() {} }, now: Date.now,
  });
  const url = `https://api.example.test/v1/public/events/${token}`;
  assert.equal((await handler(new Request(url))).status, 404);
  assert.equal(acknowledgements, 0);
  assert.equal((await handler(new Request(url, { method: 'POST' }))).status, 400);
  assert.equal(acknowledgements, 0);
  const response = await handler(new Request(url, { method: 'POST', headers: { 'X-SignalWord-Action': 'acknowledge' } }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { acknowledged: true });
  assert.equal(acknowledgements, 1);
});
test('acknowledgement proxy forwards explicit intent without user cookies', async () => {
  const result = await proxyPublicEvent({ token, method: 'POST', upstreamOrigin: 'https://backend.example.test', fetchImpl: async (_url, options) => {
    assert.equal(options.method, 'POST');
    assert.equal(options.headers['X-SignalWord-Action'], 'acknowledge');
    assert.equal(options.headers.Cookie, undefined);
    return Response.json({ acknowledged: true });
  } });
  assert.equal(result.status, 200);
});
test('failed immediate dispatch does not undo accepted work', async () => {
  await assert.doesNotReject(() => wakeDispatch('https://backend.example.test', 's'.repeat(32), async () => { throw new Error('offline'); }));
});

// Sender labels are user-controlled and must never become executable email HTML.
test('sender identity is present and escaped in provider content', async () => {
  const { renderAlertEmail } = await import('../supabase/functions/_shared/resend.ts');
  const message = renderAlertEmail({ senderName: '<img src=x onerror=alert(1)>', kind: 'test', messageType: 'initial' }, 'https://viewer.example.test/events/token');
  assert.match(message.text, /sent this SignalWord message/);
  assert.match(message.html, /&lt;img/);
  assert.doesNotMatch(message.html, /<img/);
  assert.match(message.subject, /TEST/);
});

test('authentication service outage remains retryable instead of rejecting the command', async () => {
  const { createBackendGateway } = await import('../supabase/functions/_shared/supabase.ts');
  const original = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 503 });
  try {
    await assert.rejects(createBackendGateway({ url: 'https://backend.example.test', anonKey: 'test' }).authenticate('test-jwt'), error => error.status === 503 && error.retryable === true);
  } finally { globalThis.fetch = original; }
});
