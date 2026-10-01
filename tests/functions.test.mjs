import test from 'node:test';
import assert from 'node:assert/strict';

import { createPublicEventHandler } from '../supabase/functions/public-event/index.ts';
import { createContactConfirmHandler } from '../supabase/functions/contact-confirm/index.ts';
import { createUserApiHandler } from '../supabase/functions/user-api/index.ts';
import { createDeletionStatusHandler } from '../supabase/functions/deletion-status/index.ts';
import { createBackendGateway } from '../supabase/functions/_shared/supabase.ts';
import { createLifecycleGateway } from '../supabase/functions/_shared/lifecycle.ts';
import { createDeliveryPolicy, FakeDeliveryAdapter, runDeliveryWorker } from '../supabase/functions/_shared/delivery.ts';
import { createDeliveryPayloadCipher } from '../supabase/functions/_shared/encryption.ts';
import { generateViewerToken, sha256Hex } from '../supabase/functions/_shared/tokens.ts';
import { parseCreateAlert } from '../supabase/functions/_shared/validation.ts';

const USER_ID = '00000000-0000-4000-8000-000000000010';
const EVENT_ID = '00000000-0000-4000-8000-000000000020';
const IDEMPOTENCY_KEY = '00000000-0000-4000-8000-000000000030';
const REQUEST_ID = '00000000-0000-4000-8000-000000000040';
const TOKEN = 'a'.repeat(43);

function alertRequest(overrides = {}) {
  return new Request('https://api.example.test/user-api/v1/alerts', {
    method: 'POST',
    headers: {
      Authorization: 'Bearer user-jwt',
      'Content-Type': 'application/json',
      'Idempotency-Key': IDEMPOTENCY_KEY,
      'X-Request-ID': REQUEST_ID,
      ...overrides.headers,
    },
    body: JSON.stringify(overrides.body ?? {
      kind: 'real',
      triggerMethod: 'vocalShortcut',
      clientTriggeredAt: '2026-09-24T00:00:00Z',
    }),
  });
}

function baseBackend(overrides = {}) {
  return {
    authenticate: async () => ({ id: USER_ID }),
    createAlert: async () => ({
      eventId: EVENT_ID,
      state: 'active',
      delivery: 'queued',
      serverTriggeredAt: '2026-09-24T00:00:01Z',
      reused: false,
    }),
    publicEvent: async () => null,
    ...overrides,
  };
}

function baseLifecycle(overrides = {}) {
  return {
    saveContact: async ({ name }) => ({
      contactId: '00000000-0000-4000-8000-000000000060', name,
      channel: 'email', status: 'pending', confirmationExpiresAt: '2026-09-24T00:30:00Z',
    }),
    getContact: async () => null,
    disableContact: async () => true,
    appendLocation: async () => ({ accepted: true, receivedAt: '2026-09-24T00:00:02Z' }),
    getAlertStatus: async () => null,
    resolveAlert: async (_userId, eventId) => ({ eventId, state: 'resolved', resolvedAt: '2026-09-24T00:05:00Z' }),
    deleteData: async () => ({ deletionId: '00000000-0000-4000-8000-000000000070' }),
    confirmContact: async () => false,
    ...overrides,
  };
}

function userHandler(backend, logs = [], lifecycle = baseLifecycle(), overrides = {}) {
  return createUserApiHandler({
    backend,
    lifecycle,
    delivery: createDeliveryPolicy('test', 'fake'),
    encryptPayload: async () => ({ ciphertext: 'encrypted-payload-for-outbox', keyVersion: 1 }),
    logger: { write: (event) => logs.push(event) },
    now: () => 1_000,
    generateToken: () => TOKEN,
    protectContact: async () => ({
      destinationCiphertext: 'encrypted-destination',
      destinationFingerprint: 'f'.repeat(64),
      destinationKeyVersion: 1,
      confirmationPayloadCiphertext: 'encrypted-confirmation-token',
      payloadKeyVersion: 1,
    }),
    ...overrides,
  });
}

test('user API rejects a missing bearer token without touching the backend', async () => {
  let authenticateCalls = 0;
  const handler = userHandler(baseBackend({
    authenticate: async () => { authenticateCalls += 1; return { id: USER_ID }; },
  }));
  const response = await handler(alertRequest({ headers: { Authorization: '' } }));
  const body = await response.json();

  assert.equal(response.status, 401);
  assert.equal(body.error.code, 'AUTH_REQUIRED');
  assert.equal(body.error.retryable, false);
  assert.equal(authenticateCalls, 0);
});

test('user API validates payloads and forbids body idempotency keys', async () => {
  const handler = userHandler(baseBackend());
  const response = await handler(alertRequest({
    body: {
      kind: 'real',
      triggerMethod: 'vocalShortcut',
      clientTriggeredAt: 'not-a-date',
      idempotencyKey: IDEMPOTENCY_KEY,
    },
  }));
  const body = await response.json();

  assert.equal(response.status, 400);
  assert.equal(body.error.code, 'INVALID_REQUEST');
  assert.match(body.error.message, /header/);
});

test('user API enforces the body cap when Content-Length is absent', async () => {
  const request = alertRequest({ body: { padding: 'x'.repeat(17_000) } });
  request.headers.delete('Content-Length');
  const response = await userHandler(baseBackend())(request);
  const body = await response.json();

  assert.equal(response.status, 400);
  assert.equal(body.error.code, 'INVALID_REQUEST');
  assert.match(body.error.message, /too large/i);
});

test('user API returns only the stable public create-alert projection', async () => {
  const logs = [];
  const handler = userHandler(baseBackend(), logs);
  const response = await handler(alertRequest());
  const body = await response.json();

  assert.equal(response.status, 201);
  assert.deepEqual(body, {
    eventId: EVENT_ID,
    state: 'active',
    delivery: 'queued',
    serverTriggeredAt: '2026-09-24T00:00:01Z',
    reused: false,
  });
  assert.equal(response.headers.get('X-Request-ID'), REQUEST_ID);
  assert.equal(response.headers.get('Server-Timing'), null);
  assert.equal(JSON.stringify(body).includes(TOKEN), false);
  assert.equal(JSON.stringify(logs).includes(TOKEN), false);
  assert.equal(logs[0].operation, 'alert');
  assert.deepEqual(Object.keys(logs[0]).sort(), ['durationMs', 'method', 'operation', 'requestId', 'reused', 'route', 'status']);
});

test('development v2 alert responses expose numeric phase timing without identifiers', async () => {
  let clock = Date.parse('2026-09-24T00:00:10Z');
  const handler = userHandler(baseBackend(), [], baseLifecycle(), {
    exposeServerTiming: true,
    now: () => { clock += 5; return clock; },
    network: {
      create: async () => ({
        eventId: EVENT_ID, state: 'active', delivery: 'queued',
        serverTriggeredAt: '2026-09-24T00:00:11Z', reused: false,
      }),
    },
  });
  const request = alertRequest({ body: {
    kind: 'test', triggerMethod: 'manual', clientTriggeredAt: '2026-09-24T00:00:00Z',
  } });
  const response = await handler(new Request(request.url.replace('/v1/', '/v2/'), request));
  const timing = response.headers.get('Server-Timing');
  assert.equal(response.status, 201);
  assert.match(timing, /^auth_session;dur=\d+(?:\.\d+)?, preparation;dur=\d+(?:\.\d+)?, database;dur=\d+(?:\.\d+)?, app;dur=\d+(?:\.\d+)?$/);
  assert.equal(timing.includes(USER_ID), false);
  assert.equal(timing.includes(EVENT_ID), false);
  assert.equal((await handler(alertRequest())).headers.get('Server-Timing'), null);
});

test('twenty concurrent identical creates produce one canonical event and outbox row', async () => {
  let canonical = null;
  let createCount = 0;
  let outboxCount = 0;
  let mutex = Promise.resolve();
  const backend = baseBackend({
    createAlert: async () => {
      let release;
      const previous = mutex;
      mutex = new Promise((resolve) => { release = resolve; });
      await previous;
      try {
        if (canonical) return { ...canonical, reused: true };
        await new Promise((resolve) => setTimeout(resolve, 2));
        createCount += 1;
        outboxCount += 1;
        canonical = {
          eventId: EVENT_ID,
          state: 'active',
          delivery: 'queued',
          serverTriggeredAt: '2026-09-24T00:00:01Z',
          reused: false,
        };
        return canonical;
      } finally {
        release();
      }
    },
  });
  const handler = userHandler(backend);

  const responses = await Promise.all(Array.from({ length: 20 }, () => handler(alertRequest())));
  const bodies = await Promise.all(responses.map((response) => response.json()));

  assert.equal(createCount, 1);
  assert.equal(outboxCount, 1);
  assert.deepEqual(new Set(bodies.map((body) => body.eventId)), new Set([EVENT_ID]));
  assert.equal(responses.filter((response) => response.status === 201).length, 1);
  assert.equal(responses.filter((response) => response.status === 200).length, 19);
});

test('contact setup encrypts server inputs and never returns destination or confirmation token', async () => {
  let received;
  const lifecycle = baseLifecycle({
    saveContact: async (input) => {
      received = input;
      return { contactId: '00000000-0000-4000-8000-000000000060', name: input.name,
        channel: 'email', status: 'pending', confirmationExpiresAt: '2026-09-24T00:30:00Z' };
    },
  });
  const handler = userHandler(baseBackend(), [], lifecycle);
  const response = await handler(new Request('https://api.example.test/user-api/v1/contacts', {
    method: 'POST',
    headers: { Authorization: 'Bearer user-jwt', 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Trusted person', email: 'Trusted@Example.com' }),
  }));
  const body = await response.json();

  assert.equal(response.status, 202);
  assert.equal(received.destinationCiphertext, 'encrypted-destination');
  assert.equal(received.destinationFingerprint, 'f'.repeat(64));
  assert.equal(JSON.stringify(body).includes('trusted@example.com'), false);
  assert.equal(JSON.stringify(body).includes(TOKEN), false);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
});

test('authenticated lifecycle routes preserve ownership-scoped identifiers', async () => {
  const calls = [];
  const lifecycle = baseLifecycle({
    getAlertStatus: async (userId, eventId) => {
      calls.push(['status', userId, eventId]);
      return { eventId, kind: 'real', state: 'active', triggeredAt: '2026-09-24T00:00:00Z', delivery: 'sent' };
    },
    resolveAlert: async (userId, eventId) => {
      calls.push(['resolve', userId, eventId]);
      return { eventId, state: 'resolved', resolvedAt: '2026-09-24T00:05:00Z' };
    },
    deleteData: async (userId, _jwt, receiptHash) => {
      calls.push(['delete', userId, receiptHash]);
      return { deletionId: '00000000-0000-4000-8000-000000000070' };
    },
  });
  const handler = userHandler(baseBackend(), [], lifecycle);
  const auth = { Authorization: 'Bearer user-jwt' };
  const status = await handler(new Request(`https://api.example.test/user-api/v1/alerts/${EVENT_ID}`, { headers: auth }));
  const resolve = await handler(new Request(`https://api.example.test/user-api/v1/alerts/${EVENT_ID}/resolve`, { method: 'POST', headers: auth }));
  const deletion = await handler(new Request('https://api.example.test/user-api/v1/data', {
    method: 'DELETE', headers: { ...auth, 'X-Deletion-Receipt': TOKEN },
  }));

  assert.equal(status.status, 200);
  assert.equal(resolve.status, 200);
  assert.equal(deletion.status, 200);
  assert.deepEqual(calls, [
    ['status', USER_ID, EVENT_ID], ['resolve', USER_ID, EVENT_ID,], ['delete', USER_ID, await sha256Hex(TOKEN)],
  ]);
});

test('deletion status settles a lost DELETE response by receipt without auth', async () => {
  const seen = [];
  const handler = createDeletionStatusHandler(async (hash) => {
    seen.push(hash);
    return '00000000-0000-4000-8000-000000000070';
  });
  const url = 'https://api.example.test/deletion-status/v1/deletions/status';
  const missing = await handler(new Request(url));
  const confirmed = await handler(new Request(url, { headers: { 'X-Deletion-Receipt': TOKEN } }));
  assert.equal(missing.status, 400);
  assert.equal(confirmed.status, 200);
  assert.deepEqual(await confirmed.json(), { deleted: true });
  assert.deepEqual(seen, [await sha256Hex(TOKEN)]);
  assert.equal(confirmed.headers.get('Cache-Control'), 'no-store');
  const unavailable = await createDeletionStatusHandler(async () => { throw new Error('database unavailable'); })(
    new Request(url, { headers: { 'X-Deletion-Receipt': TOKEN } }),
  );
  assert.equal(unavailable.status, 503);
});

test('location enrichment uses the canonical plural route and preserves ownership', async () => {
  let received;
  const lifecycle = baseLifecycle({
    appendLocation: async (userId, eventId, location) => {
      received = { userId, eventId, location };
      return { accepted: true, receivedAt: '2026-09-24T00:00:02Z' };
    },
  });
  const response = await userHandler(baseBackend(), [], lifecycle)(new Request(
    `https://api.example.test/user-api/v1/alerts/${EVENT_ID}/locations`,
    {
      method: 'POST',
      headers: { Authorization: 'Bearer user-jwt', 'Content-Type': 'application/json' },
      body: JSON.stringify({ location: {
        latitude: -33.8688, longitude: 151.2093,
        horizontalAccuracyM: 12, capturedAt: new Date(1_000).toISOString(),
      } }),
    },
  ));

  assert.equal(response.status, 202);
  assert.equal(received.userId, USER_ID);
  assert.equal(received.eventId, EVENT_ID);
  assert.equal(received.location.latitude, -33.8688);
});

test('contact setup cannot select another owner through its request body', async () => {
  const handler = userHandler(baseBackend(), [], baseLifecycle({
    saveContact: async () => { assert.fail('untrusted ownership must not reach the privileged write'); },
  }));
  const response = await handler(new Request('https://api.example.test/user-api/v1/contacts', {
    method: 'POST',
    headers: { Authorization: 'Bearer user-jwt', 'Content-Type': 'application/json' },
    body: JSON.stringify({ name: 'Trusted', email: 'trusted@example.test', userId: EVENT_ID }),
  }));
  assert.equal(response.status, 400);
});

test('contact setup fails closed without backend credentials', async () => {
  const gateway = createLifecycleGateway({ url: 'https://project.supabase.co', anonKey: 'publishable-key', serviceRoleKey: 'server-key' });
  await assert.rejects(gateway.saveContact({}, 'user-jwt'),
    (error) => error.status === 503 && error.code === 'SERVICE_UNAVAILABLE');
});

test('contact setup uses backend credentials and exposes rate limits as bounded retry guidance', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async (_url, options) => {
    assert.equal(options.headers.Authorization, 'Bearer backend-only-key');
    assert.equal(options.headers.apikey, 'backend-only-key');
    assert.equal(JSON.parse(options.body).p_user_id, USER_ID);
    return new Response(JSON.stringify({ message: 'RATE_LIMITED' }), {
    status: 400,
    headers: { 'Content-Type': 'application/json' },
    });
  };
  try {
    const gateway = createLifecycleGateway({ url: 'https://project.supabase.co', anonKey: 'publishable-key', serviceRoleKey: 'server-key', serviceRoleKey: 'backend-only-key' });
    await assert.rejects(
      gateway.saveContact({
        userId: USER_ID, name: 'Trusted', destinationCiphertext: 'encrypted-destination',
        destinationFingerprint: 'f'.repeat(64), destinationKeyVersion: 1,
        confirmationTokenHashHex: 'a'.repeat(64),
        confirmationPayloadCiphertext: 'encrypted-confirmation', payloadKeyVersion: 1,
        provider: 'fake',
      }, 'user-jwt'),
      (error) => error.code === 'RATE_LIMITED' && error.status === 429
        && error.retryable === true && error.retryAfterSeconds === 3600,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('contact confirmation consumes only a valid one-time token and hides token validity', async () => {
  let hash;
  const lifecycle = baseLifecycle({ confirmContact: async (value) => { hash = value; return true; } });
  const handler = createContactConfirmHandler({ lifecycle, logger: { write() {} }, now: () => 1_000 });
  const confirmed = await handler(new Request(`https://api.example.test/contact-confirm/v1/contacts/confirm/${TOKEN}`, { method: 'POST' }));
  const invalid = await handler(new Request('https://api.example.test/contact-confirm/v1/contacts/confirm/short', { method: 'POST' }));

  assert.equal(confirmed.status, 200);
  assert.equal(hash, await sha256Hex(TOKEN));
  assert.equal(invalid.status, 410);
  assert.equal((await invalid.json()).error.message, 'This confirmation link is unavailable.');
});

test('recipient withdrawal requires an explicit action and hashes the same capability', async () => {
  let hash;
  const handler = createContactConfirmHandler({
    lifecycle: baseLifecycle({ withdrawContact: async (value) => { hash = value; return true; } }),
    logger: { write() {} }, now: () => Date.now(),
  });
  const request = new Request(`https://api.example.test/contact-confirm/v1/contacts/confirm/${TOKEN}`, {
    method: 'POST', headers: { 'X-SignalWord-Action': 'withdraw' },
  });
  const response = await handler(request);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { withdrawn: true });
  assert.equal(hash, await sha256Hex(TOKEN));
});

test('public API hashes the token and returns only the viewer projection', async () => {
  let receivedHash;
  const projection = {
    kind: 'test',
    displayName: 'Sample user',
    state: 'active',
    triggeredAt: '2026-09-24T00:00:01Z',
    lastUpdatedAt: '2026-09-24T00:00:01Z',
    guidance: { summary: 'Contact Sample user now.' },
    internalSecret: 'must-not-cross-boundary',
  };
  const logs = [];
  const handler = createPublicEventHandler({
    backend: baseBackend({ publicEvent: async (hash) => { receivedHash = hash; return projection; } }),
    logger: { write: (event) => logs.push(event) },
    now: () => 1_000,
  });
  const response = await handler(new Request(`https://api.example.test/public-event/v1/public/events/${TOKEN}`));

  assert.equal(response.status, 200);
  const responseBody = await response.json();
  assert.equal(responseBody.internalSecret, undefined);
  assert.deepEqual(responseBody, {
    kind: 'test',
    displayName: 'Sample user',
    state: 'active',
    triggeredAt: '2026-09-24T00:00:01Z',
    lastUpdatedAt: '2026-09-24T00:00:01Z',
    guidance: { summary: 'Contact Sample user now.' },
  });
  assert.equal(receivedHash, await sha256Hex(TOKEN));
  assert.equal(receivedHash.includes(TOKEN), false);
  assert.equal(JSON.stringify(logs).includes(TOKEN), false);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.match(response.headers.get('X-Request-ID'), /^[0-9a-f-]{36}$/);
  assert.equal(response.headers.get('Referrer-Policy'), 'no-referrer');
  assert.match(response.headers.get('Content-Security-Policy'), /default-src 'none'/);
  assert.match(response.headers.get('Strict-Transport-Security'), /max-age=/);
});

test('invalid and unknown public tokens share the same safe unavailable response', async () => {
  const handler = createPublicEventHandler({
    backend: baseBackend({ publicEvent: async () => null }),
    logger: { write() {} },
    now: () => 1_000,
  });
  const invalid = await handler(new Request('https://api.example.test/public-event/v1/public/events/short'));
  const unknown = await handler(new Request(`https://api.example.test/public-event/v1/public/events/${TOKEN}`));
  const [invalidBody, unknownBody] = await Promise.all([invalid.json(), unknown.json()]);

  assert.equal(invalid.status, 404);
  assert.equal(unknown.status, 404);
  assert.equal(invalidBody.error.code, 'NOT_FOUND');
  assert.equal(unknownBody.error.code, 'NOT_FOUND');
  assert.equal(invalidBody.error.message, unknownBody.error.message);
  assert.equal(invalidBody.error.retryable, unknownBody.error.retryable);
});

test('viewer tokens contain 256 random bits encoded as unpadded base64url', () => {
  const tokens = new Set(Array.from({ length: 100 }, generateViewerToken));
  assert.equal(tokens.size, 100);
  for (const token of tokens) assert.match(token, /^[A-Za-z0-9_-]{43}$/);
});

test('backend gateway uses server credentials and maps the internal RPC result', async () => {
  const originalFetch = globalThis.fetch;
  let request;
  globalThis.fetch = async (url, init) => {
    request = { url, init };
    return new Response(JSON.stringify([{
      event_id: EVENT_ID,
      event_state: 'active',
      delivery_status: 'queued',
      server_triggered_at: '2026-09-24T00:00:01Z',
      reused: false,
    }]), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
  try {
    const gateway = createBackendGateway({ url: 'https://project.supabase.co/', anonKey: 'publishable-key', serviceRoleKey: 'server-key' });
    const result = await gateway.createAlert({
      kind: 'real', triggerMethod: 'manual', clientTriggeredAt: '2026-09-24T00:00:00Z',
    }, USER_ID, IDEMPOTENCY_KEY, {
      viewerToken: TOKEN,
      provider: 'fake',
      payloadCiphertext: 'encrypted-payload-for-outbox',
      payloadKeyVersion: 1,
    }, 'user-jwt');

    assert.equal(result.eventId, EVENT_ID);
    assert.equal(request.url, 'https://project.supabase.co/rest/v1/rpc/gateway_create_or_reuse_alert');
    assert.equal(request.init.headers.Authorization, 'Bearer server-key');
    assert.equal(request.init.headers.apikey, 'server-key');
    const rpcBody = JSON.parse(request.init.body);
    assert.equal(rpcBody.p_idempotency_key, IDEMPOTENCY_KEY);
    assert.equal(rpcBody.p_viewer_token, TOKEN);
    assert.equal(rpcBody.p_delivery_provider, 'fake');
    assert.equal(rpcBody.p_delivery_payload_ciphertext, 'encrypted-payload-for-outbox');
    assert.equal('idempotencyKey' in rpcBody, false);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('malformed successful database results fail closed as retryable', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(JSON.stringify([{ event_id: EVENT_ID, reused: false }]), {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
  });
  try {
    const gateway = createBackendGateway({ url: 'https://project.supabase.co', anonKey: 'publishable-key', serviceRoleKey: 'server-key' });
    await assert.rejects(
      gateway.createAlert({
        kind: 'real', triggerMethod: 'manual', clientTriggeredAt: '2026-09-24T00:00:00Z',
      }, USER_ID, IDEMPOTENCY_KEY, {
        viewerToken: TOKEN,
        provider: 'fake',
        payloadCiphertext: 'encrypted-payload-for-outbox',
        payloadKeyVersion: 1,
      }, 'user-jwt'),
      (error) => error.code === 'SERVICE_UNAVAILABLE' && error.retryable === true,
    );
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('delivery payload is AES-GCM encrypted and versioned at rest', async () => {
  const key = generateViewerToken();
  const cipher = createDeliveryPayloadCipher(key, 3);
  const ciphertext = await cipher.encrypt(TOKEN);

  assert.equal(ciphertext.includes(TOKEN), false);
  assert.deepEqual(await cipher.decrypt(ciphertext, 3), { viewerToken: TOKEN });
  await assert.rejects(cipher.decrypt(ciphertext, 2), /key version/);
});

test('transactional outbox survives request completion and retries with the same viewer capability', async () => {
  const delivery = {
    deliveryId: '00000000-0000-4000-8000-000000000050',
    eventId: EVENT_ID,
    kind: 'real',
    messageType: 'initial',
    provider: 'fake',
    providerIdempotencyKey: `alert/${EVENT_ID}/initial`,
    payloadCiphertext: 'opaque-ciphertext',
    payloadKeyVersion: 1,
    destinationCiphertext: 'encrypted-destination',
    destinationKeyVersion: 1,
    attemptCount: 1,
  };
  let available = true;
  const finishes = [];
  const outbox = {
    claim: async () => available ? [delivery] : [],
    finish: async (_deliveryId, _workerId, result) => {
      finishes.push(result);
      available = result.succeeded === false;
      return true;
    },
  };
  let attempts = 0;
  const sentTokens = [];
  const adapter = {
    send: async ({ viewerToken, idempotencyKey }) => {
      attempts += 1;
      sentTokens.push(viewerToken);
      assert.equal(idempotencyKey, `alert/${EVENT_ID}/initial`);
      if (attempts === 1) throw new Error('simulated provider outage');
      return { providerMessageId: 'fake/message-1' };
    },
  };
  const cipher = { decrypt: async () => ({ viewerToken: TOKEN }) };
  const destinationCipher = { decryptEmail: async () => 'trusted@example.com' };

  const first = await runDeliveryWorker({ workerId: REQUEST_ID, outbox, cipher, destinationCipher, adapter });
  const second = await runDeliveryWorker({ workerId: REQUEST_ID, outbox, cipher, destinationCipher, adapter });

  assert.deepEqual(first, { claimed: 1, sent: 0, failed: 1, leaseLost: 0 });
  assert.deepEqual(second, { claimed: 1, sent: 1, failed: 0, leaseLost: 0 });
  assert.deepEqual(sentTokens, [TOKEN, TOKEN]);
  assert.deepEqual(finishes.map((result) => result.succeeded), [false, true]);
});

test('fake delivery is impossible in production and missing production delivery fails closed', () => {
  assert.throws(() => createDeliveryPolicy('production', 'fake'), /cannot be enabled/);
  assert.throws(() => createDeliveryPolicy('prod', 'fake'), /APP_ENV/);
  assert.throws(() => new FakeDeliveryAdapter('production'), /cannot run/);
  assert.throws(
    () => createDeliveryPolicy('production', 'none').assertAvailable('real'),
    (error) => error.code === 'SERVICE_UNAVAILABLE' && error.retryable === true,
  );
});

test('implausibly old or future location is omitted without blocking the alert', () => {
  const now = Date.parse('2026-09-24T12:00:00Z');
  const input = (capturedAt) => ({
    kind: 'real',
    triggerMethod: 'manual',
    clientTriggeredAt: '2026-09-24T12:00:00Z',
    location: { latitude: -33.8, longitude: 151.2, horizontalAccuracyM: 10, capturedAt },
  });

  assert.ok(parseCreateAlert(input('2026-09-24T11:59:50Z'), now).location);
  assert.equal(parseCreateAlert(input('2026-09-23T11:59:59Z'), now).location, undefined);
  assert.equal(parseCreateAlert(input('2026-09-24T12:05:01Z'), now).location, undefined);
});

test('accepted alerts survive logger and best-effort wakeup failures',async()=>{
 const logs={push(){throw Error('telemetry unavailable');}};
 const handler=userHandler(baseBackend(),logs,baseLifecycle(),{wake(){throw Error('wakeup unavailable');}});
 const response=await handler(alertRequest());assert.equal(response.status,201);
 assert.equal((await response.json()).eventId,EVENT_ID);
});
test('contact confirmation survives logging failure',async()=>{
 const handler=createContactConfirmHandler({lifecycle:baseLifecycle({confirmContact:async()=>true}),now:()=>1000,logger:{write(){throw Error('unavailable');}}});
 const response=await handler(new Request(`https://api.example.test/v1/contacts/confirm/${TOKEN}`,{method:'POST'}));
 assert.equal(response.status,200);assert.deepEqual(await response.json(),{confirmed:true});
});
