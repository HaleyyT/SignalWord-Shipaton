import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

const SHA256 = /^[a-f0-9]{64}$/;
const STATUS = new Set(['sent', 'delivered', 'failed']);

function timestamp(input, key) {
  const value = Date.parse(input[key]);
  if (!Number.isFinite(value)) throw new Error(`TIMESTAMP_REQUIRED:${key}`);
  return value;
}

function count(snapshot, key, minimum = 0) {
  const value = snapshot?.[key];
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error(`COUNT_REQUIRED:${key}`);
  return value;
}

/** Redact and judge a provider-dashboard replay captured around one controlled TEST receipt. */
export function evaluateProviderReplay(input) {
  if (input.environment !== 'development' || !/^[a-f0-9]{40}$/.test(input.sourceCommit ?? '')) {
    throw new Error('DEVELOPMENT_COMMIT_REQUIRED');
  }
  if (!/^[a-z0-9][a-z0-9-]{2,63}$/.test(input.fixtureLabel ?? '') || !SHA256.test(input.providerEventDigest ?? '')) {
    throw new Error('PSEUDONYMOUS_FIXTURE_REQUIRED');
  }
  const capturedBeforeAt = timestamp(input, 'capturedBeforeAt');
  const replayRequestedAt = timestamp(input, 'replayRequestedAt');
  const providerAttemptAt = timestamp(input, 'providerAttemptAt');
  const capturedAfterAt = timestamp(input, 'capturedAfterAt');
  if (!(capturedBeforeAt <= replayRequestedAt && replayRequestedAt <= providerAttemptAt && providerAttemptAt <= capturedAfterAt)) {
    throw new Error('REPLAY_TIMELINE_INVALID');
  }
  if (!SHA256.test(input.providerAttemptDigest ?? '')) throw new Error('PROVIDER_ATTEMPT_REQUIRED');
  const before = {
    deliveryCount: count(input.before, 'deliveryCount', 1),
    attemptCount: count(input.before, 'attemptCount', 1),
    receiptCount: count(input.before, 'receiptCount', 1),
    status: input.before?.status,
  };
  const after = {
    deliveryCount: count(input.after, 'deliveryCount'),
    attemptCount: count(input.after, 'attemptCount'),
    receiptCount: count(input.after, 'receiptCount'),
    status: input.after?.status,
  };
  if (!STATUS.has(before.status) || !STATUS.has(after.status)) throw new Error('DELIVERY_STATUS_REQUIRED');
  const assertions = {
    freshProviderAttemptObserved: providerAttemptAt > capturedBeforeAt && input.replayStatus === 'succeeded',
    signedEndpointAccepted: input.webhookStatus === 202,
    receiptDeduplicated: after.receiptCount === before.receiptCount,
    deliveryCountUnchanged: after.deliveryCount === before.deliveryCount,
    attemptCountUnchanged: after.attemptCount === before.attemptCount,
    terminalStateUnchanged: after.status === before.status && ['delivered', 'failed'].includes(after.status),
  };
  return {
    environment: 'development',
    sourceCommit: input.sourceCommit,
    fixtureLabel: input.fixtureLabel,
    providerEventDigest: input.providerEventDigest,
    capturedBeforeAt: input.capturedBeforeAt,
    replayRequestedAt: input.replayRequestedAt,
    providerAttemptAt: input.providerAttemptAt,
    providerAttemptDigest: input.providerAttemptDigest,
    capturedAfterAt: input.capturedAfterAt,
    replayStatus: input.replayStatus,
    webhookStatus: input.webhookStatus,
    before,
    after,
    assertions,
    passed: Object.values(assertions).every(Boolean),
  };
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [source, output] = process.argv.slice(2);
  if (!source || !output) throw new Error('PRIVATE_INPUT_AND_NEW_OUTPUT_REQUIRED');
  const result = evaluateProviderReplay(JSON.parse(readFileSync(source, 'utf8')));
  writeFileSync(output, `${JSON.stringify(result, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
  console.log(JSON.stringify({ passed: result.passed, output }));
  if (!result.passed) process.exitCode = 1;
}
