import test from 'node:test';
import assert from 'node:assert/strict';
import { evaluateProviderReplay } from '../scripts/provider-replay-evidence.mjs';

const input = {
  environment: 'development', sourceCommit: 'a'.repeat(40), fixtureLabel: 'test-delivery-01',
  providerEventDigest: 'b'.repeat(64), capturedBeforeAt: '2026-09-29T11:00:00Z',
  replayRequestedAt: '2026-09-29T11:01:00Z', providerAttemptAt: '2026-09-29T11:01:01Z',
  providerAttemptDigest: 'c'.repeat(64),
  capturedAfterAt: '2026-09-29T11:02:00Z', replayStatus: 'succeeded', webhookStatus: 202,
  before: { deliveryCount: 1, attemptCount: 1, receiptCount: 2, status: 'delivered' },
  after: { deliveryCount: 1, attemptCount: 1, receiptCount: 2, status: 'delivered' },
};

test('fresh signed replay passes only when provider activity is new and storage is unchanged', () => {
  assert.equal(evaluateProviderReplay(input).passed, true);
  for (const change of [
    { webhookStatus: 503 },
    { after: { ...input.after, receiptCount: 3 } },
    { after: { ...input.after, attemptCount: 2 } },
  ]) assert.equal(evaluateProviderReplay({ ...input, ...change }).passed, false);
  assert.throws(() => evaluateProviderReplay({ ...input, providerAttemptAt: input.capturedBeforeAt }), /TIMELINE/);
});

test('private extras are not copied into replay evidence', () => {
  const report = evaluateProviderReplay({ ...input, token: 'private', before: { ...input.before, email: 'private' } });
  assert.equal(JSON.stringify(report).includes('private'), false);
});

test('zero or missing correlated baseline counts are rejected', () => {
  for (const key of ['deliveryCount', 'attemptCount', 'receiptCount']) {
    assert.throws(() => evaluateProviderReplay({ ...input, before: { ...input.before, [key]: 0 } }), /COUNT_REQUIRED/);
    const before = { ...input.before }; delete before[key];
    assert.throws(() => evaluateProviderReplay({ ...input, before }), /COUNT_REQUIRED/);
  }
});

test('a replay request or old event screen cannot stand in for a fresh provider attempt', () => {
  const missingAttempt = { ...input }; delete missingAttempt.providerAttemptDigest;
  assert.throws(() => evaluateProviderReplay(missingAttempt), /PROVIDER_ATTEMPT_REQUIRED/);
  const missingTimestamp = { ...input }; delete missingTimestamp.providerAttemptAt;
  assert.throws(() => evaluateProviderReplay(missingTimestamp), /TIMESTAMP_REQUIRED:providerAttemptAt/);
});
