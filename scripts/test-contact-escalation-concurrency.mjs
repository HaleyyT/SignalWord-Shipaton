import { acquireLocalFixtureLock, localContainer, localRestContainer, localWorkdir } from "./local-fixture.mjs";
acquireLocalFixtureLock();
// Local Docker-only fault tests. Never accepts a hosted database connection.
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";
const user = randomUUID();
const contacts = [randomUUID(), randomUUID(), randomUUID()];
const command = randomUUID();
const worker = randomUUID();
const database = localContainer;
function sql(statement) {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", [
      "exec",
      "-i",
      database,
      "psql",
      "-X",
      "-qAt",
      "-v",
      "ON_ERROR_STOP=1",
      "-U",
      "postgres",
      "-d",
      "postgres",
    ], { stdio: ["pipe", "pipe", "pipe"] });
    let output = "", error = "";
    child.stdout.on("data", (chunk) => output += chunk);
    child.stderr.on("data", (chunk) => error += chunk);
    child.on("error", reject);
    child.on(
      "exit",
      (code) => code === 0 ? resolve(output.trim()) : reject(new Error(error)),
    );
    child.stdin.end("set signalword.local_fixture='true';"+statement);
  });
}
const asUser =
  `set local role authenticated; set local request.jwt.claim.sub='${user}';`;
const payload = JSON.stringify(
  [1, 2, 3].map((i) => ({
    token: (String(i) + user.replaceAll("-", "")).padEnd(43, String(i)),
    ciphertext: String(i).repeat(48),
    keyVersion: 1,
  })),
);
async function waitForLock(application) {
  // Poll for an actual sleeping transaction; timing alone is not evidence that
  // the first transaction acquired its locks before the competing request.
  for (let i = 0; i < 100; i++) {
    if (
      await sql(
        `select count(*) from pg_stat_activity where application_name='${application}' and wait_event='PgSleep';`,
      ) === "1"
    ) return;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error("Timed out waiting for lock holder");
}
try {
  assert.equal(
    await sql(
      "select count(*) from public.alert_deliveries where status='queued';",
    ),
    "0",
    "Concurrency fixture requires an idle local outbox",
  );
  await sql(
    `insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
    values('${user}','authenticated','authenticated','concurrency-${user}@example.test','{}','{}',now(),now());
    insert into public.profiles(id,display_name) values('${user}','Concurrency fixture');
    ${
      contacts.map((id, i) =>
        `insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
    values('${id}','${user}','Fixture ${i}','email',repeat('${i}',48),repeat('${i}',64),1,'confirmed',now());`
      ).join("\n")
    }
    begin; ${asUser}
    set local role service_role; select * from public.gateway_create_routed_alert('${user}','${command}','real','manual','fake','${payload}'::jsonb);
    commit;`,
  );
  const event = await sql(
    `select id from public.alert_events where user_id='${user}' and idempotency_key='${command}';`,
  );
  const label = `network-${user}`;
  const first = sql(
    `begin;set local application_name='${label}'; select count(*) from public.claim_alert_deliveries('${worker}',3);select pg_sleep(3);commit;`,
  );
  await waitForLock(label);
  assert.equal(
    await sql(
      `select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${event}';`,
    ),
    "0",
  );
  assert.match(await first, /3/);
  console.log("PASS concurrent workers cannot claim the same deliveries");
  await sql(
    `update public.alert_deliveries set lease_owner=null,lease_expires_at=null where alert_event_id='${event}';`,
  );
  const resolve = sql(
    `begin;set local application_name='${label}';${asUser}select * from public.resolve_alert('${user}','${event}');select pg_sleep(3);commit;`,
  );
  await waitForLock(label);
  assert.equal(
    await sql(
      `select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${event}';`,
    ),
    "0",
  );
  await resolve;
  assert.equal(
    await sql(
      `select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${event}';`,
    ),
    "0",
  );
  assert.equal(
    await sql(
      `select count(*) from public.alert_deliveries where alert_event_id='${event}' and last_error_code='EVENT_RESOLVED';`,
    ),
    "3",
  );
  console.log(
    "PASS resolution serializes with competing dispatch and cancels unsent recipients",
  );
  const nextKey = randomUUID();
  const nextPayload = JSON.stringify(['a','b','c'].map(i => ({token:(i+user.replaceAll('-','')).padEnd(43,i),ciphertext:i.repeat(48),keyVersion:1})));
  const create = `begin;${asUser}set local role service_role; select * from public.gateway_create_routed_alert('${user}','${nextKey}','test','manual','fake','${nextPayload}'::jsonb);commit;`;
  await Promise.all([sql(create),sql(create)]);
  assert.equal(await sql(`select count(*) from public.alert_events where user_id='${user}' and idempotency_key='${nextKey}';`),'1');
  const nextEvent=await sql(`select id from public.alert_events where user_id='${user}' and idempotency_key='${nextKey}';`);
  assert.equal(await sql(`select count(*) from public.alert_deliveries where alert_event_id='${nextEvent}';`),'3');
  console.log('PASS overlapping idempotent TEST acceptance creates one recipient batch');
  const token=JSON.parse(nextPayload)[0].token;
  const ack=sql(`begin;set local application_name='${label}';select public.acknowledge_public_event(extensions.digest('${token}','sha256'));select pg_sleep(3);commit;`);
  await waitForLock(label);
  assert.equal(await sql(`select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${nextEvent}';`),'0');
  await ack;
  assert.equal(await sql(`select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${nextEvent}';`),'3');
  console.log('PASS concurrent acknowledgement delays a locked claim but never cancels escalation');
  await sql(`update public.alert_deliveries set lease_owner=null,lease_expires_at=null where alert_event_id='${nextEvent}';`);
  const withdrawal=sql(`begin;set local application_name='${label}';${asUser}select public.disable_contact('${user}','${contacts[2]}');select pg_sleep(3);commit;`);
  await waitForLock(label);
  const duringWithdrawal = Number(await sql(`select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${nextEvent}';`));
  await withdrawal;
  const afterWithdrawal = Number(await sql(`select count(*) from public.claim_alert_deliveries('${randomUUID()}',3) where event_id='${nextEvent}';`));
  // Lock contention may defer other recipients too; none may be lost or duplicated.
  assert.equal(duringWithdrawal + afterWithdrawal, 2);
  assert.equal(await sql(`select count(*) from public.alert_deliveries where alert_event_id='${nextEvent}' and trusted_contact_id='${contacts[2]}' and status='failed' and lease_owner is null;`),'1');
  console.log('PASS concurrent withdrawal prevents its recipient claim while preserving other recipients');
  const consentToken = randomUUID();
  await sql(`insert into public.contact_confirmation_tokens(trusted_contact_id,token_hash,expires_at,consumed_at)
    values('${contacts[0]}',extensions.digest('${consentToken}','sha256'),now()+interval '30 minutes',now());`);
  const withdrawFirst = sql(`begin;set local application_name='${label}';select public.withdraw_contact(extensions.digest('${consentToken}','sha256'));select pg_sleep(3);commit;`);
  await waitForLock(label);
  const confirmationAfterWithdrawal = sql(`select public.confirm_contact(extensions.digest('${consentToken}','sha256'));`);
  await withdrawFirst;
  assert.equal(await confirmationAfterWithdrawal, 'f');
  assert.equal(await sql(`select status from public.trusted_contacts where id='${contacts[0]}';`), 'disabled');
  console.log('PASS confirmation retry cannot restore consent when withdrawal owns the token lock');

  // Local fixture reset only: exercise the opposite ordering on the same token.
  await sql(`update public.trusted_contacts set status='confirmed',confirmed_at=now() where id='${contacts[0]}';`);
  const confirmFirst = sql(`begin;set local application_name='${label}';select public.confirm_contact(extensions.digest('${consentToken}','sha256'));select pg_sleep(3);commit;`);
  await waitForLock(label);
  const withdrawalAfterConfirmation = sql(`select public.withdraw_contact(extensions.digest('${consentToken}','sha256'));`);
  await confirmFirst;
  assert.equal(await withdrawalAfterConfirmation, 't');
  assert.equal(await sql(`select status from public.trusted_contacts where id='${contacts[0]}';`), 'disabled');
  console.log('PASS withdrawal remains final when confirmation retry owns the token lock');
} finally {
  await sql(`delete from public.rate_limit_buckets where subject_hash in (
    select extensions.digest(t.token_hash || convert_to(a.action,'UTF8'),'sha256')
    from public.viewer_tokens t join public.alert_events e on e.id=t.alert_event_id
    cross join (values ('read'),('ack')) a(action) where e.user_id='${user}');
    delete from auth.users where id='${user}';
    delete from public.safety_journal_outbox where user_id='${user}';`);
}
