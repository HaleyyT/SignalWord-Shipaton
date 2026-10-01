import test from 'node:test';
import assert from 'node:assert/strict';
import { operationalProblems, checkOperations, reportHeartbeat } from '../scripts/check-operations.mjs';
const healthy = () => ({ dispatchConfigured: true,
  journal: {pending:0,oldestPendingSeconds:0}, provider:{callbackOverdue:0,deliveryReportOverdue:0},
  dispatchHTTP: { lastCompletedAt: new Date().toISOString(), lastStatus: 200, timedOut: false, overdue: 0 },
  abuse: { signupsLastHour: 0, invitationsLastHour: 0 },
  delivery: { queued: 0, unknown: 0, oldestQueuedSeconds: 0, expiredLeases: 0 },
  contactDelivery: { queued: 0, unknown: 0, oldestQueuedSeconds: 0, expiredLeases: 0 },
  schedules: ['signalword-dispatch-sweep','signalword-delivery-lease-recovery','signalword-hourly-retention']
    .map(name => ({ name, active: true, lastSuccessAt: new Date().toISOString() })),
});
test('cron SQL success cannot hide an HTTP failure or signup abuse', () => {
  const health = healthy();
  health.dispatchHTTP.lastStatus = 500;
  health.abuse.signupsLastHour = 101;
  assert.deepEqual(operationalProblems(health), ['DISPATCH_HTTP_UNHEALTHY', 'SIGNUP_VOLUME_HIGH']);
});
test('external heartbeat reports failure without including private diagnostics', async () => {
  let path;
  const ok = await reportHeartbeat('https://hc-ping.com/00000000-0000-4000-8000-000000000001', false, async (url, init) => {
    path = url.pathname; assert.equal(init.body, undefined); assert.equal(init.redirect, 'manual');
    return new Response('OK');
  });
  assert.equal(ok, true); assert.ok(path.endsWith('/fail'));
  assert.equal(await reportHeartbeat('https://hc-ping.com/00000000-0000-4000-8000-000000000001', true, async () => new Response('OK (not found)')), false);
});
test('operational readiness fails closed for missing configuration, invalid metrics, and stopped schedules', () => {
  assert.deepEqual(operationalProblems(healthy()), []);
  assert.ok(operationalProblems(null).length > 0);
  const health = healthy(); health.dispatchConfigured = false;
  health.delivery.unknown = 1; health.contactDelivery.oldestQueuedSeconds = 61;
  health.schedules[0].active = false;
  assert.deepEqual(operationalProblems(health), ['DISPATCH_CONFIGURATION_MISSING','ALERT_OUTCOME_UNKNOWN','CONTACT_QUEUE_OVER_60_SECONDS','SCHEDULE_UNHEALTHY:signalword-dispatch-sweep']);
});
test('operator notification contains only safe problem codes and handles notification outage', async () => {
  const calls = [];
  const result = await checkOperations({ backendOrigin: 'https://backend.example', monitorKey: 'secret', notificationURL: 'https://operator.example/hook',
    fetchImpl: async (url, init) => {
      calls.push({ url, init });
      if (calls.length === 1) throw new Error('secret URL with private payload');
      return new Response(null, { status: 503 });
    },
  });
  assert.deepEqual(result, { problems: ['HEALTH_RPC_UNAVAILABLE'], notified: false });
  assert.ok(!calls[1].init.body.includes('secret'));
  assert.ok(!('Authorization' in calls[1].init.headers));
});
test('a healthy check does not send an operator message', async () => {
  let requests = 0;
  const result = await checkOperations({ backendOrigin: 'https://backend.example', monitorKey: 'secret', notificationURL: 'https://operator.example/hook',
    fetchImpl: async () => { requests++; return Response.json({problems:[]}); },
  });
  assert.equal(requests, 1);
  assert.deepEqual(result.problems, []);
});
test('timer metrics detect overdue work, failed escalation and missing sweeps',()=>{
  const health=healthy();
  health.checkIns={overdue:1,failed:1,schedules:[]};
  assert.deepEqual(operationalProblems(health),['CHECK_IN_OVERDUE','CHECK_IN_FAILED','SCHEDULE_UNHEALTHY:signalword-check-in-expiry','SCHEDULE_UNHEALTHY:signalword-check-in-retention']);
});

test('journal and provider delays remain visible without claiming delivery failed',()=>{
 const health=healthy();health.journal.oldestPendingSeconds=61;health.provider.callbackOverdue=1;health.provider.deliveryReportOverdue=1;health.delivery.queued=101;
 assert.deepEqual(operationalProblems(health),['ALERT_QUEUE_BACKLOG','JOURNAL_PERSISTENCE_OVERDUE','PROVIDER_CALLBACK_OVERDUE','PROVIDER_DELIVERY_REPORT_OVERDUE']);
});

test('heartbeat rejects redirects without following a capability to another origin',async()=>{
 let calls=0;
 const accepted=await reportHeartbeat('https://hc-ping.com/00000000-0000-4000-8000-000000000001',true,async(_url,init)=>{
  calls++;assert.equal(init.redirect,'manual');
  return new Response(null,{status:302,headers:{Location:'https://untrusted.example/'}});
 });
 assert.equal(accepted,false);assert.equal(calls,1);
});
