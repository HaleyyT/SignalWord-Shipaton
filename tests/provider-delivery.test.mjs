import test from 'node:test';
import assert from 'node:assert/strict';

import {
  DeliveryAttemptError,
  runContactVerificationWorker,
  runDeliveryWorker,
} from '../supabase/functions/_shared/delivery.ts';
import { createContactDataProtection } from '../supabase/functions/_shared/encryption.ts';
import {
  renderAlertEmail,
  renderContactVerificationEmail,
  ResendDeliveryAdapter,
} from '../supabase/functions/_shared/resend.ts';
import { createDispatchHandler } from '../supabase/functions/dispatch-deliveries/index.ts';
import { createResendWebhookHandler } from '../supabase/functions/resend-webhook/index.ts';

const TOKEN = 'a'.repeat(43);
const EVENT_ID = '00000000-0000-4000-8000-000000000020';
const CONTACT_ID = '00000000-0000-4000-8000-000000000060';
const WORKER_ID = '00000000-0000-4000-8000-000000000040';

function resendConfiguration(overrides = {}) {
  return {
    apiKey: `re_${'a'.repeat(24)}`,
    from: 'SignalWord <alerts@signalword.example>',
    publicViewerBaseUrl: 'https://signalword.example',
    publicConfirmationBaseUrl: 'https://signalword.example',
    environment: 'production',
    ...overrides,
  };
}

test('alert copy unmistakably separates TEST, REAL, and resolved messages', () => {
  const base = { eventId: EVENT_ID, recipient: 'trusted@example.com', viewerToken: TOKEN,
    idempotencyKey: `alert/${EVENT_ID}/initial`, messageType: 'initial' };
  const rehearsal = renderAlertEmail({ ...base, kind: 'test' }, 'https://signalword.example/events/token');
  const real = renderAlertEmail({ ...base, kind: 'real' }, 'https://signalword.example/events/token');
  const resolved = renderAlertEmail({ ...base, kind: 'real', messageType: 'resolved' }, 'https://signalword.example/events/token');

  assert.match(rehearsal.subject, /^TEST/);
  assert.match(rehearsal.text, /NO EMERGENCY/);
  assert.doesNotMatch(real.subject, /TEST/);
  assert.match(real.text, /does not contact emergency services/);
  assert.match(resolved.subject, /resolved/i);
});

test('resolved rehearsals remain unmistakably TEST in every email format', () => {
  const message = renderAlertEmail({ eventId: EVENT_ID, recipient: 'trusted@example.com',
    viewerToken: TOKEN, idempotencyKey: `alert/${EVENT_ID}/resolved`,
    messageType: 'resolved', kind: 'test' }, 'https://signalword.example/events/token');
  assert.match(message.subject, /^TEST — NO EMERGENCY:/);
  assert.match(message.subject, /resolved/i);
  assert.match(message.text, /TEST — NO EMERGENCY/);
  assert.match(message.html, /TEST — NO EMERGENCY/);
  assert.match(message.text, /Do not contact emergency services because of this test/);
});

test('contact confirmation copy explains consent, expiry, and limitations', () => {
  const message = renderContactVerificationEmail(`https://signalword.example/confirm/${TOKEN}`);
  assert.match(message.text, /Confirm only if/);
  assert.match(message.text, /expires in 30 minutes/);
  assert.match(message.text, /does not contact emergency services/);
});

test('Resend adapter sends an idempotent request without leaking credentials into content', async () => {
  let captured;
  const adapter = new ResendDeliveryAdapter(resendConfiguration(), async (url, init) => {
    captured = { url, init };
    return Response.json({ id: 'provider-message-1' });
  });
  const result = await adapter.send({
    eventId: EVENT_ID,
    kind: 'real',
    messageType: 'initial',
    recipient: 'trusted@example.com',
    viewerToken: TOKEN,
    idempotencyKey: `alert/${EVENT_ID}/initial`,
  });

  assert.equal(result.providerMessageId, 'provider-message-1');
  assert.equal(captured.url, 'https://api.resend.com/emails');
  assert.equal(captured.init.headers['Idempotency-Key'], `alert/${EVENT_ID}/initial`);
  assert.equal(JSON.parse(captured.init.body).to[0], 'trusted@example.com');
  assert.equal(captured.init.body.includes(resendConfiguration().apiKey), false);
});

test('Resend adapter quarantines uncertain outcomes and distinguishes explicit rejection', async () => {
  const terminal = new ResendDeliveryAdapter(resendConfiguration(), async () => new Response(null, { status: 422 }));
  const concurrent = new ResendDeliveryAdapter(resendConfiguration(), async () =>
    Response.json({ name: 'concurrent_idempotent_requests' }, { status: 409 }));
  const conflicting = new ResendDeliveryAdapter(resendConfiguration(), async () =>
    Response.json({ name: 'invalid_idempotent_request' }, { status: 409 }));
  const delivery = { eventId: EVENT_ID, kind: 'real', messageType: 'initial', recipient: 'trusted@example.com',
    viewerToken: TOKEN, idempotencyKey: `alert/${EVENT_ID}/initial` };
  for (const status of [408, 429, 502, 503, 504]) {
    const temporary = new ResendDeliveryAdapter(resendConfiguration(), async () => new Response(null, { status }));
    await assert.rejects(temporary.send(delivery), (error) => error instanceof DeliveryAttemptError && error.safeCode === 'OUTCOME_UNKNOWN' && !error.retryable);
  }
  await assert.rejects(terminal.send(delivery), (error) => error instanceof DeliveryAttemptError && !error.retryable);
  await assert.rejects(concurrent.send(delivery), (error) => error instanceof DeliveryAttemptError && error.safeCode === 'OUTCOME_UNKNOWN' && !error.retryable);
  await assert.rejects(conflicting.send(delivery), (error) => error instanceof DeliveryAttemptError && !error.retryable);
  for (const failingFetch of [
    async () => { throw new Error('response lost'); },
    async () => Response.json({}),
  ]) {
    const ambiguous = new ResendDeliveryAdapter(resendConfiguration(), failingFetch);
    await assert.rejects(ambiguous.send(delivery), (error) => error instanceof DeliveryAttemptError && error.safeCode === 'OUTCOME_UNKNOWN' && !error.retryable);
  }
});

test('contact encryption round-trips without storing plaintext destination or token', async () => {
  const key = Buffer.alloc(32, 7).toString('base64url');
  const fingerprintKey = Buffer.alloc(32, 8).toString('base64url');
  const protection = createContactDataProtection(key, fingerprintKey, 2);
  const destination = await protection.encryptDestination('Trusted@Example.com');
  const confirmation = await protection.encryptConfirmationToken(TOKEN);
  assert.equal(destination.includes('trusted@example.com'), false);
  assert.equal(confirmation.includes(TOKEN), false);
  assert.equal(await protection.decryptDestination(destination, 2), 'trusted@example.com');
  assert.equal(await protection.decryptConfirmationToken(confirmation, 2), TOKEN);
});

test('workers finalize terminal failures and report a lost lease after provider acceptance', async () => {
  const alertFinishes = [];
  const delivery = {
    deliveryId: CONTACT_ID, eventId: EVENT_ID, kind: 'real', messageType: 'initial', provider: 'resend',
    providerIdempotencyKey: `alert/${EVENT_ID}/initial`, payloadCiphertext: 'payload', payloadKeyVersion: 1,
    destinationCiphertext: 'destination', destinationKeyVersion: 1, attemptCount: 1,
  };
  const terminal = await runDeliveryWorker({
    workerId: WORKER_ID,
    outbox: { claim: async () => [delivery], finish: async (_id, _worker, result) => { alertFinishes.push(result); return true; } },
    cipher: { decrypt: async () => ({ viewerToken: TOKEN }) },
    destinationCipher: { decryptEmail: async () => 'trusted@example.com' },
    adapter: { provider: 'resend', send: async () => { throw new DeliveryAttemptError('REJECTED', false); } },
  });
  assert.equal(terminal.failed, 1);
  assert.equal(alertFinishes[0].retryable, false);

  const contact = await runContactVerificationWorker({
    workerId: WORKER_ID,
    outbox: { claim: async () => [{ ...delivery, contactId: CONTACT_ID }], finish: async () => false },
    confirmationCipher: { decryptToken: async () => TOKEN },
    destinationCipher: { decryptEmail: async () => 'trusted@example.com' },
    adapter: { provider: 'resend', sendVerification: async () => ({ providerMessageId: 'accepted' }) },
  });
  assert.deepEqual(contact, { claimed: 1, sent: 0, failed: 0, leaseLost: 1 });
});

test('dispatch endpoint fails closed and never invokes work for a bad secret', async () => {
  let calls = 0;
  const handler = createDispatchHandler({
    dispatchSecret: 's'.repeat(32),
    run: async () => { calls += 1; return { alerts: {}, confirmations: {} }; },
  });
  assert.equal((await handler(new Request('https://api.example.test', { method: 'POST' }))).status, 401);
  assert.equal(calls, 0);
  assert.equal((await handler(new Request('https://api.example.test', {
    method: 'POST', headers: { Authorization: `Bearer ${'s'.repeat(32)}` },
  }))).status, 200);
  assert.equal(calls, 1);
});

async function signedWebhookRequest(body, secretBytes, overrides = {}) {
  const id = overrides.id ?? 'msg_webhook_1';
  const timestamp = overrides.timestamp ?? String(Math.floor(Date.now() / 1000));
  const raw = new TextEncoder().encode(body);
  const key = await crypto.subtle.importKey('raw', secretBytes, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const signature = Buffer.from(await crypto.subtle.sign(
    'HMAC', key, new TextEncoder().encode(`${id}.${timestamp}.${body}`),
  )).toString('base64');
  return new Request('https://api.example.test/resend-webhook', {
    method: 'POST', body,
    headers: { 'svix-id': id, 'svix-timestamp': timestamp, 'svix-signature': `v1,${signature}` },
  });
}

test('webhook verifies the raw body before parsing and accepts replay-safe valid events', async () => {
  const secretBytes = new Uint8Array(32).fill(9);
  const secret = `whsec_${Buffer.from(secretBytes).toString('base64')}`;
  const applied = [];
  const handler = createResendWebhookHandler({ webhookSecret: secret, apply: async (event) => { applied.push(event); return true; } });
  const invalid = new Request('https://api.example.test', {
    method: 'POST', body: '{invalid json',
    headers: { 'svix-id': 'invalid', 'svix-timestamp': String(Math.floor(Date.now() / 1000)), 'svix-signature': 'v1,bad' },
  });
  assert.equal((await handler(invalid)).status, 401);
  assert.equal(applied.length, 0);

  const body = JSON.stringify({ type: 'email.delivered', data: { email_id: 'provider-message-1' } });
  assert.equal((await handler(await signedWebhookRequest(body, secretBytes))).status, 202);
  assert.deepEqual(applied[0], {
    providerEventId: 'msg_webhook_1', providerMessageId: 'provider-message-1', eventType: 'delivered',
  });
});

test('webhook rejects altered bodies and correctly signed stale or future requests before storage', async () => {
  const secretBytes = Buffer.alloc(32, 9);
  const handler = createResendWebhookHandler({
    webhookSecret: `whsec_${secretBytes.toString('base64')}`,
    apply: async () => { assert.fail('untrusted webhook must not reach storage'); },
  });
  const body = JSON.stringify({ type: 'email.delivered', data: { email_id: 'provider-message-1' } });
  const signed = await signedWebhookRequest(body, secretBytes);
  // A valid signature for one body must not authorize a different event.
  const altered = new Request(signed.url, {
    method: 'POST', headers: signed.headers, body: body.replace('delivered', 'failed'),
  });
  assert.equal((await handler(altered)).status, 401);
  for (const offset of [-600, 600]) {
    const timestamp = String(Math.floor(Date.now() / 1000) + offset);
    assert.equal((await handler(await signedWebhookRequest(body, secretBytes, { timestamp }))).status, 401);
  }
});

test('webhook cancels oversized streamed bodies without trusting Content-Length', async () => {
  let cancelled = false;
  const body = new ReadableStream({
    pull(controller) { controller.enqueue(new Uint8Array(8192)); },
    cancel() { cancelled = true; },
  });
  const handler = createResendWebhookHandler({
    webhookSecret: `whsec_${Buffer.alloc(32, 9).toString('base64')}`,
    apply: async () => { assert.fail('oversized webhook must not reach storage'); },
  });
  const request = new Request('https://api.example.test/resend-webhook', {
    method: 'POST', body, duplex: 'half',
  });
  assert.equal((await handler(request)).status, 413);
  assert.equal(cancelled, true);
});

test('provider correlation contains only the hash of the stable send key', async () => {
  let sent;
  const adapter = new ResendDeliveryAdapter(resendConfiguration(), async (_, init) => {
    sent = JSON.parse(init.body);
    return Response.json({ id: 'correlated-message' });
  });
  const idempotencyKey = `alert/${EVENT_ID}/initial`;
  await adapter.send({ eventId: EVENT_ID, kind: 'test', messageType: 'initial',
    recipient: 'trusted@example.test', viewerToken: TOKEN, idempotencyKey });
  const digest = Buffer.from(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(idempotencyKey))).toString('hex');
  assert.deepEqual(sent.tags, [{ name: 'signalword_delivery', value: digest }]);
});

test('signed correlation reaches reconciliation; storage failures request retry', async () => {
  const secret = `whsec_${Buffer.alloc(32, 7).toString('base64')}`;
  const payload = { type: 'email.delivered', data: { email_id: 'correlated-message', tags: { signalword_delivery: 'a'.repeat(64) } } };
  let received;
  const handler = createResendWebhookHandler({ webhookSecret: secret, apply: async (event) => { received = event; throw new Error('database unavailable'); } });
  const response = await handler(await signedWebhookRequest(JSON.stringify(payload), Buffer.alloc(32, 7)));
  assert.equal(response.status, 503);
  assert.equal(received.deliveryCorrelation, 'a'.repeat(64));
  const invalid = createResendWebhookHandler({ webhookSecret: secret, apply: async () => { assert.fail('invalid tag must not reach storage'); } });
  payload.data.tags.signalword_delivery = 'invalid';
  assert.equal((await invalid(await signedWebhookRequest(JSON.stringify(payload), Buffer.alloc(32, 7)))).status, 400);
});
