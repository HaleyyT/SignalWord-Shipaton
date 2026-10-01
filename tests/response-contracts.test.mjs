import test from 'node:test';
import assert from 'node:assert/strict';
import { parseUserResponse } from '../supabase/functions/_shared/response-contracts.ts';

const id = '00000000-0000-4000-8000-000000000020';
const time = '2026-09-27T00:00:00.123456+00:00';
const status = { eventId: id, kind: 'real', state: 'active', delivery: 'unknown', triggeredAt: time };
const examples = {
  profile: { displayName: 'Alex' },
  createAlert: { eventId: id, state: 'active', delivery: 'queued', serverTriggeredAt: time, reused: false },
  contact: { contactId: id, name: 'Sam', channel: 'email', status: 'confirmed' },
  alertStatus: status,
  disableContact: { disabled: true },
  appendLocation: { accepted: true, receivedAt: time },
  resolveAlert: { eventId: id, state: 'resolved', resolvedAt: time },
  deleteData: { deletionId: id },
};
for (const [contract, example] of Object.entries(examples)) {
  test(`${contract} validates its response and drops unexpected private fields`, () => {
    assert.deepEqual(parseUserResponse(contract, { ...example, destination_ciphertext: 'private' }), example);
    for (const key of Object.keys(example)) {
      const malformed = { ...example };
      delete malformed[key];
      assert.throws(() => parseUserResponse(contract, malformed), error => error.status === 503 && error.retryable);
    }
  });
}
test('recovery rejects a corrupt record instead of presenting incomplete success', () => {
  assert.deepEqual(parseUserResponse('recovery', [status]), [status]);
  assert.throws(() => parseUserResponse('recovery', [status, { ...status, kind: 'invalid' }]));
  assert.throws(() => parseUserResponse('recovery', null));
  assert.throws(() => parseUserResponse('alertStatus', { ...status, acknowledgedAt: 'yesterday' }));
  assert.deepEqual(parseUserResponse('alertStatus', { ...status, acknowledgedAt: null }), status);
});
