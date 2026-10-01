import { acquireLocalFixtureLock, localContainer, localRestContainer, localWorkdir } from "./local-fixture.mjs";
acquireLocalFixtureLock();
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import assert from "node:assert/strict";
const user = randomUUID();
function sql(statement) {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", [
      "exec",
      "-i",
      localContainer,
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
    child.stdout.on("data", (x) => output += x);
    child.stderr.on("data", (x) => error += x);
    child.on("error", reject);
    child.on(
      "exit",
      (code) => code === 0 ? resolve(output.trim()) : reject(new Error(error)),
    );
    child.stdin.end("set signalword.local_fixture='true';"+statement);
  });
}
const auth =
  `set local role service_role;set local request.jwt.claim.sub='${user}';`;
async function wait(label) {
  for (let i = 0; i < 100; i++) {
    if (
      await sql(
        `select count(*) from pg_stat_activity where application_name='${label}' and wait_event='PgSleep';`,
      ) === "1"
    ) return;
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
  throw new Error("Lock holder did not start");
}
async function start() {
  const key = randomUUID();
  const payloads = JSON.stringify(
    [1, 2, 3].map((i) => ({
      hash: (key.replaceAll("-", "") + String(i)).padEnd(64, "a"),
      ciphertext: String(i).repeat(48),
      keyVersion: 1,
    })),
  );
  await sql(
    `begin;${auth}select public.gateway_change_check_in('${user}','${key}','start',null,15,'fake','${payloads}');commit;`,
  );
  return await sql(
    `select id from public.check_in_timers where user_id='${user}' and state='active';`,
  );
}
try {
  assert.equal(
    await sql(
      "select count(*) from public.check_in_timers where state='active';",
    ),
    "0",
    "Requires an idle local timer environment",
  );
  await sql(
    `insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values('${user}','authenticated','authenticated','timer-race-${user}@example.test','{}','{}',now(),now());
 insert into public.profiles(id,display_name) values('${user}','Timer race');
 insert into public.trusted_contacts(user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at) values('${user}','Fixture','email',repeat('a',48),repeat('a',64),1,'confirmed',now());`,
  );
  let timer = await start();
  await sql(
    `update public.check_in_timers set deadline=now()-interval '58 seconds',grace_ends_at=now()+interval '2 seconds' where id='${timer}';`,
  );
  const label = `timer-${user}`;
  const cancel = sql(
    `begin;set local application_name='${label}';${auth}select public.gateway_change_check_in('${user}','${randomUUID()}','cancel','${timer}');select pg_sleep(4);commit;`,
  );
  await wait(label);
  await sql("select pg_sleep(2.1);");
  assert.equal(await sql("select public.sweep_check_ins();"), "0");
  await cancel;
  assert.equal(
    await sql(`select state from public.check_in_timers where id='${timer}';`),
    "cancelled",
  );
  assert.equal(
    await sql(
      `select count(*) from public.alert_events where user_id='${user}';`,
    ),
    "0",
  );
  console.log(
    "PASS cancellation winning the user lock prevents competing expiry",
  );
  timer = await start();
  await sql(
    `update public.check_in_timers set deadline=now()-interval '58 seconds',grace_ends_at=now()+interval '2 seconds' where id='${timer}';`,
  );
  const extend = sql(
    `begin;set local application_name='${label}';${auth}select public.gateway_change_check_in('${user}','${randomUUID()}','extend','${timer}',15);select pg_sleep(4);commit;`,
  );
  await wait(label);
  await sql("select pg_sleep(2.1);");
  assert.equal(await sql("select public.sweep_check_ins();"), "0");
  await extend;
  assert.equal(
    await sql(
      `select count(*) from public.check_in_timers where id='${timer}' and state='active' and deadline>now();`,
    ),
    "1",
  );
  console.log(
    "PASS extension winning the user lock preserves the new server deadline",
  );
  await sql(
    `update public.check_in_timers set deadline=now()-interval '2 minutes',grace_ends_at=now()-interval '1 minute' where id='${timer}';`,
  );
  const expire = sql(
    `begin;set local application_name='${label}';select public.sweep_check_ins();select pg_sleep(3);commit;`,
  );
  await wait(label);
  assert.equal(await sql("select public.sweep_check_ins();"), "0");
  const late = sql(
    `begin;${auth}select public.gateway_change_check_in('${user}','${randomUUID()}','cancel','${timer}')->>'state';commit;`,
  );
  await expire;
  assert.equal(await late, "escalated");
  assert.equal(
    await sql(
      `select count(*) from public.alert_events where user_id='${user}' and cause='missed_check_in';`,
    ),
    "1",
  );
  assert.equal(
    await sql(
      `select count(*) from public.alert_deliveries d join public.alert_events e on e.id=d.alert_event_id where e.user_id='${user}';`,
    ),
    "1",
  );
  console.log(
    "PASS expiry winning the lock produces one incident and cannot be silently cancelled",
  );
} finally {
  await sql(`delete from public.rate_limit_buckets where subject_hash in (
    select extensions.digest(t.token_hash || convert_to(a.action,'UTF8'),'sha256')
    from public.viewer_tokens t join public.alert_events e on e.id=t.alert_event_id
    cross join (values ('read'),('ack')) a(action) where e.user_id='${user}');
    delete from auth.users where id='${user}';
    delete from public.safety_journal_outbox where user_id='${user}';`);
}
