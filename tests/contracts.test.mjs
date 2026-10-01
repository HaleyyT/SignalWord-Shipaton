import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { parseCreateAlert } from '../supabase/functions/_shared/validation.ts';

test('shared creation request fixture passes backend validation', () => {
  const request = JSON.parse(readFileSync('contracts/v1/create-alert.request.json', 'utf8'));
  const parsed = parseCreateAlert(request, Date.parse('2026-09-21T00:00:30Z'));
  assert.equal(parsed.kind, 'test');
  assert.equal(parsed.triggerMethod, 'vocalShortcut');
});

test('viewer contract fixture exposes only the public projection', () => {
  const event = JSON.parse(readFileSync('contracts/v1/public-event.response.json', 'utf8'));
  assert.equal(event.location.freshness, 'live');
  assert.deepEqual(Object.keys(event).sort(), ['displayName', 'guidance', 'kind', 'lastUpdatedAt', 'location', 'state', 'triggeredAt']);
  assert.equal('eventId' in event, false);
  assert.equal('contactDestination' in event, false);
});
