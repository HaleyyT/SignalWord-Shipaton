import { parseUserResponse } from "../supabase/functions/_shared/response-contracts.ts";
import { readFileSync } from 'node:fs';

function fixture(name) {
  return JSON.parse(readFileSync(`contracts/v1/${name}.json`, 'utf8'));
}

function requireKeys(value, keys, name) {
  for (const key of keys) {
    if (!(key in value)) {
      throw new Error(`${name} is missing required key ${key}.`);
    }
  }
}

function requireRFC3339(value, name) {
  if (Number.isNaN(Date.parse(value))) {
    throw new Error(`${name} must be an RFC 3339 timestamp.`);
  }
}

const createRequest = fixture('create-alert.request');
const createResponse = fixture('create-alert.response');
const publicEvent = fixture('public-event.response');

requireKeys(createRequest, ['kind', 'triggerMethod', 'clientTriggeredAt'], 'create-alert request');
requireKeys(createResponse, ['eventId', 'state', 'delivery', 'serverTriggeredAt', 'reused'], 'create-alert response');
requireKeys(publicEvent, ['kind', 'displayName', 'state', 'triggeredAt', 'lastUpdatedAt', 'guidance'], 'public-event response');

requireRFC3339(createRequest.clientTriggeredAt, 'create-alert request clientTriggeredAt');
requireRFC3339(createResponse.serverTriggeredAt, 'create-alert response serverTriggeredAt');
requireRFC3339(publicEvent.triggeredAt, 'public-event response triggeredAt');
requireRFC3339(publicEvent.lastUpdatedAt, 'public-event response lastUpdatedAt');

if (!['test', 'real'].includes(createRequest.kind) || !['test', 'real'].includes(publicEvent.kind)) {
  throw new Error('Alert kind must be test or real.');
}
if (!['active', 'resolved', 'expired'].includes(publicEvent.state)) {
  throw new Error('Public event state is unsupported by the viewer.');
}
if (publicEvent.location && !['live', 'recent', 'stale', 'unavailable'].includes(publicEvent.location.freshness)) {
  throw new Error('Public event location freshness is unsupported by the viewer.');
}

console.log('Shared API contract fixtures are valid.');

for (const [contract, name] of Object.entries({
  profile: 'profile', contact: 'contact', alertStatus: 'alert-status', recovery: 'recovery',
  resolveAlert: 'resolve-alert', deleteData: 'delete-data', disableContact: 'disable-contact',
  appendLocation: 'append-location', createAlert: 'create-alert',
})) parseUserResponse(contract, fixture(`${name}.response`));
console.log('Authenticated response contract fixtures are valid.');
for (const [contract, name] of [['contactNetwork','contact-network'],['recipients','recipients']]) {
  parseUserResponse(contract, JSON.parse(readFileSync(`contracts/v2/${name}.response.json`, 'utf8')));
}
console.log('Recipient-scoped v2 response fixtures are valid.');
parseUserResponse('checkIn', JSON.parse(readFileSync('contracts/v2/check-in.response.json', 'utf8')));
