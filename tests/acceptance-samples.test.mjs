import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { recordConcurrentSamples } from '../scripts/acceptance-samples.mjs';

test('a failed request cannot discard successes or leak private response/error values', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'signalword-samples-'));
  try {
    const output = join(dir, 'burst.jsonl');
    const secret = 'private-capability@example.test';
    const result = await recordConcurrentSamples({ count: 3, output, request: async i => {
      if (i === 1) throw new Error(secret);
      return { status: i === 2 ? 503 : 200, valid: true, body: secret, url: secret };
    } });
    const recorded = readFileSync(output, 'utf8');
    assert.equal(recorded.trim().split('\n').length, 3);
    assert.equal(recorded.includes(secret), false);
    assert.equal(result.successful, 1);
    assert.equal(result.samples[1].transportError, true);
    assert.equal(result.samples[2].status, 503);
    await assert.rejects(recordConcurrentSamples({ count: 1, output, request: async () => ({ status: 200, valid: true }) }), /EEXIST/);
    assert.equal(readFileSync(output, 'utf8'), recorded);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('bounds the burst before issuing any request', async () => {
  let called = false;
  await assert.rejects(recordConcurrentSamples({ count: 21, output: '/unused', request: async () => { called = true; } }), /BURST_SIZE/);
  assert.equal(called, false);
});

test('retains only allowlisted numeric phase timings and derives client-edge time', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'signalword-timings-'));
  try {
    const output = join(dir, 'burst.jsonl');
    const result = await recordConcurrentSamples({ count: 1, output, request: async () => ({
      status: 200,
      valid: true,
      phases: { authSessionMs: 4.6, preparationMs: 2, databaseMs: 3, appMs: 5, secret: 'must-not-leak' },
    }) });
    const recorded = readFileSync(output, 'utf8');
    assert.deepEqual(result.samples[0].phases, {
      authSessionMs: 5,
      preparationMs: 2,
      databaseMs: 3,
      appMs: 5,
      clientEdgeMs: Math.max(0, result.samples[0].durationMs - 5),
    });
    assert.equal(recorded.includes('secret'), false);
    assert.equal(recorded.includes('must-not-leak'), false);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
