import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateHostedLoadEvidence } from '../scripts/hosted-load-evidence.mjs';

const rows = (count, status, durationMs) => Array.from({ length: count }, (_, sequence) => ({ sequence, status, durationMs, valid: true, transportError: false }));
const deliveries = Array.from({ length: 10 }, (_, index) => ({
  senderLabel: `sender-${String(index + 1).padStart(2, '0')}`,
  deliveryLabel: `delivery-${String(index + 1).padStart(2, '0')}`,
  providerMessageDigest: index.toString(16).padStart(64, '0'), attemptCount: 1,
  providerAcceptedMs: 900, signedCallbackCount: 1,
}));
const fixture = {
  metadata: { environment: 'development', sourceCommit: 'a'.repeat(40), declaredBeforeRun: true, recordedAt: '2026-09-29T11:00:00Z' },
  first: rows(10, 201, 1000), duplicate: rows(10, 200, 1100), reads: rows(20, 200, 1500),
  provider: { capturedBeforeCleanup: true, incidentCount: 10, uniqueIncidentCount: 10,
    deliveryCountBeforeDuplicates: 10, deliveryCountAfterDuplicates: 10, queuedCount: 0, unknownOutcomeCount: 0, deliveries },
};

test('complete correlated load evidence passes unchanged budgets', () => {
  assert.equal(evaluateHostedLoadEvidence(fixture).passed, true);
});

test('failed latency, duplicate delivery, missing callback, or unknown work remains failed', () => {
  const cases = [
    { ...fixture, duplicate: rows(10, 200, 2001) },
    { ...fixture, provider: { ...fixture.provider, deliveryCountAfterDuplicates: 11 } },
    { ...fixture, provider: { ...fixture.provider, deliveries: deliveries.map((row, index) => index ? row : { ...row, signedCallbackCount: 0 }) } },
    { ...fixture, provider: { ...fixture.provider, unknownOutcomeCount: 1 } },
  ];
  for (const value of cases) assert.equal(evaluateHostedLoadEvidence(value).passed, false);
});

test('output contains aggregates and assertions but no private extras', () => {
  const report = evaluateHostedLoadEvidence({ ...fixture, metadata: { ...fixture.metadata, token: 'private' }, provider: { ...fixture.provider, email: 'private' } });
  assert.equal(JSON.stringify(report).includes('private'), false);
});

test('missing provider counts and incomplete provider rows are rejected or failed', () => {
  for (const key of ['incidentCount', 'uniqueIncidentCount', 'deliveryCountBeforeDuplicates', 'deliveryCountAfterDuplicates', 'queuedCount', 'unknownOutcomeCount']) {
    const provider = { ...fixture.provider }; delete provider[key];
    assert.throws(() => evaluateHostedLoadEvidence({ ...fixture, provider }), /PROVIDER_COUNT_REQUIRED/);
  }
  assert.equal(evaluateHostedLoadEvidence({ ...fixture, provider: { ...fixture.provider, deliveryCountBeforeDuplicates: 0, deliveryCountAfterDuplicates: 0 } }).passed, false);
  assert.equal(evaluateHostedLoadEvidence({ ...fixture, provider: { ...fixture.provider, deliveryCountBeforeDuplicates: 11, deliveryCountAfterDuplicates: 11 } }).passed, false);
});

test('direct evaluator calls reject duplicate, missing, negative, and malformed samples', () => {
  const cases = [
    { ...fixture, first: fixture.first.slice(1) },
    { ...fixture, first: fixture.first.map(row => ({ ...row, sequence: 0 })) },
    { ...fixture, first: fixture.first.map((row, index) => index ? row : { ...row, durationMs: -1 }) },
    { ...fixture, first: fixture.first.map((row, index) => index ? row : { ...row, status: 0 }) },
  ];
  for (const value of cases) assert.throws(() => evaluateHostedLoadEvidence(value));
});
