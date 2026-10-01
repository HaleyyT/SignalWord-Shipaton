import test from 'node:test';
import assert from 'node:assert/strict';
import { proxyContactConfirmation } from '../apps/viewer/api/v1/contacts/confirm/[token].mjs';

const TOKEN = 'a'.repeat(43);

test('confirmation proxy rejects malformed capabilities without contacting upstream', async () => {
  let called = false;
  const result = await proxyContactConfirmation({
    token: 'short', upstreamOrigin: 'https://api.example.test',
    fetchImpl: async () => { called = true; return Response.json({ confirmed: true }); },
  });
  assert.equal(result.status, 410);
  assert.equal(called, false);
});

test('confirmation proxy forwards a single POST and exposes only a boolean result', async () => {
  let request;
  const result = await proxyContactConfirmation({
    token: TOKEN, upstreamOrigin: 'https://api.example.test/contact-confirm',
    fetchImpl: async (url, init) => { request = { url, init }; return Response.json({ confirmed: true, secret: 'omit' }); },
  });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { confirmed: true });
  assert.equal(request.init.method, 'POST');
  assert.equal(request.url, `https://api.example.test/contact-confirm/v1/contacts/confirm/${TOKEN}`);
  assert.equal(request.init.redirect, 'error');
});

test('confirmation proxy maps expired and provider failures to safe states', async () => {
  const expired = await proxyContactConfirmation({
    token: TOKEN, upstreamOrigin: 'https://api.example.test',
    fetchImpl: async () => Response.json({ error: { message: 'details' } }, { status: 410 }),
  });
  assert.deepEqual(expired.body, { confirmed: false, unavailable: true });

  const failed = await proxyContactConfirmation({
    token: TOKEN, upstreamOrigin: 'https://api.example.test',
    fetchImpl: async () => { throw new Error('network'); },
  });
  assert.equal(failed.status, 503);
  assert.deepEqual(failed.body, { confirmed: false, retryable: true });
});

test('withdrawal proxy sends the action header and returns only the withdrawal result', async () => {
  let action;
  const result = await proxyContactConfirmation({
    token: TOKEN, action: 'withdraw', upstreamOrigin: 'https://api.example.test/contact-confirm',
    fetchImpl: async (_url, init) => {
      action = init.headers['X-SignalWord-Action'];
      return Response.json({ withdrawn: true, privateField: 'omit' });
    },
  });
  assert.equal(action, 'withdraw');
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { withdrawn: true });
});
