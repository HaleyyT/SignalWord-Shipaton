import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

import handler, { proxyPublicEvent } from '../apps/viewer/api/v1/public/events/[token].mjs';

const TOKEN = 'v'.repeat(43);

for (const method of ['GET', 'POST']) {
  test(`hosted public URL routes ${method} to the event function`, async () => {
    const config = JSON.parse(readFileSync(new URL('../apps/viewer/vercel.json', import.meta.url)));
    const rewrite = config.rewrites.find(({ source }) => source === '/v1/public/events/:token');
    assert.deepEqual(rewrite, {
      source: '/v1/public/events/:token',
      destination: '/api/v1/public/events/:token',
    });
    assert.equal(rewrite.destination.replace(':token', TOKEN), `/api/v1/public/events/${TOKEN}`);

    const originalFetch = globalThis.fetch;
    const originalOrigin = process.env.SIGNALWORD_PUBLIC_EVENT_ORIGIN;
    const upstreamCalls = [];
    globalThis.fetch = async (url, options) => {
      upstreamCalls.push({ url, options });
      return Response.json(method === 'GET' ? { kind: 'test' } : { acknowledged: true });
    };
    process.env.SIGNALWORD_PUBLIC_EVENT_ORIGIN = 'https://project.supabase.co/functions/v1/public-event';
    const headers = {};
    const response = {
      setHeader(name, value) { headers[name] = value; return this; },
      status(code) { this.statusCode = code; return this; },
      json(body) { this.body = body; return this; },
    };
    try {
      await handler({
        method,
        query: { token: TOKEN },
        headers: method === 'POST' ? { 'x-signalword-action': 'acknowledge' } : {},
      }, response);
      assert.equal(response.statusCode, 200);
      assert.deepEqual(response.body, method === 'GET' ? { kind: 'test' } : { acknowledged: true });
      assert.equal(upstreamCalls.length, 1);
      assert.equal(upstreamCalls[0].url, `https://project.supabase.co/functions/v1/public-event/v1/public/events/${TOKEN}`);
      assert.equal(upstreamCalls[0].options.method, method);
      assert.equal(upstreamCalls[0].options.headers['X-SignalWord-Action'], method === 'POST' ? 'acknowledge' : undefined);
      assert.equal(headers['Cache-Control'], 'no-store');
    } finally {
      globalThis.fetch = originalFetch;
      if (originalOrigin === undefined) delete process.env.SIGNALWORD_PUBLIC_EVENT_ORIGIN;
      else process.env.SIGNALWORD_PUBLIC_EVENT_ORIGIN = originalOrigin;
    }
  });
}

test('same-origin viewer proxy forwards only the opaque token to the configured public function', async () => {
  let requestUrl;
  const result = await proxyPublicEvent({
    token: TOKEN,
    upstreamOrigin: 'https://project.supabase.co/functions/v1/public-event',
    fetchImpl: async (url) => {
      requestUrl = url;
      return new Response(JSON.stringify({ kind: 'test' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    },
  });

  assert.equal(requestUrl, `https://project.supabase.co/functions/v1/public-event/v1/public/events/${TOKEN}`);
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { kind: 'test' });
  assert.equal(result.headers['Cache-Control'], 'no-store');
  assert.equal(result.headers['Referrer-Policy'], 'no-referrer');
});

test('same-origin viewer proxy rejects malformed tokens without contacting upstream', async () => {
  let called = false;
  const result = await proxyPublicEvent({
    token: 'short',
    upstreamOrigin: 'https://project.supabase.co/functions/v1/public-event',
    fetchImpl: async () => { called = true; throw new Error('should not run'); },
  });

  assert.equal(called, false);
  assert.equal(result.status, 404);
  assert.equal(result.body.error.code, 'NOT_FOUND');
});

test('same-origin viewer proxy preserves bounded retry signals and fails closed', async () => {
  const limited = await proxyPublicEvent({
    token: TOKEN,
    upstreamOrigin: 'https://project.supabase.co/functions/v1/public-event',
    fetchImpl: async () => new Response(JSON.stringify({ error: { code: 'RATE_LIMITED' } }), {
      status: 429,
      headers: { 'Retry-After': '30' },
    }),
  });
  const insecure = await proxyPublicEvent({
    token: TOKEN,
    upstreamOrigin: 'http://attacker.example',
    fetchImpl: async () => { throw new Error('should not run'); },
  });

  assert.equal(limited.status, 429);
  assert.equal(limited.headers['Retry-After'], '30');
  assert.equal(insecure.status, 503);
  assert.equal(insecure.body.error.retryable, true);
});
