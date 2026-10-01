import {
  acquireLocalFixtureLock,
  localContainer,
  localRestContainer,
  localWorkdir,
} from "./local-fixture.mjs";
acquireLocalFixtureLock();
/** Local account-backup drill. It only removes its own generated fixture records. */
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createServer } from "node:http";
import { ControlService } from "../infrastructure/control/service.mjs";
const container = localContainer;
function docker(args, input = "") {
  return new Promise((resolve, reject) => {
    const child = spawn("docker", ["exec", "-i", container, ...args], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let output = "", error = "";
    child.stdout.on("data", (b) => output += b);
    child.stderr.on("data", (b) => error += b);
    child.on("error", reject);
    child.on("close", (code) => code ? reject(Error(error)) : resolve(output));
    child.stdin.end(input);
  });
}
const sql = (text) =>
  docker([
    "psql",
    "-X",
    "-qAt",
    "-v",
    "ON_ERROR_STOP=1",
    "-U",
    "postgres",
    "-d",
    "postgres",
  ], text);
assert.equal(
  (await sql(
    "select (select count(*) from auth.users)||'|'||(select count(*) from public.profiles)||'|'||(select count(*) from vault.secrets);",
  )).trim(),
  "0|0|0",
  "Use an empty local account fixture database",
);
// Restore reconciliation affects application state globally; refuse every occupied
// application/auth table, preserving Supabase's schema version bookkeeping.
await sql(`do $$ declare r record; n bigint; begin
 for r in select schemaname,tablename from pg_tables where schemaname in ('public','auth') and not(schemaname='auth' and tablename='schema_migrations') loop
 execute format('select count(*) from %I.%I',r.schemaname,r.tablename) into n;
 if n>0 then raise exception 'Drill requires empty application tables'; end if;
 end loop; end $$;`);
const data = new Map(), objects = new Map();
let storageFailure = false;
const storage = {
  get: async (k) => structuredClone(data.get(k)),
  put: async (k, v) => {
    if (typeof k === "string") data.set(k, structuredClone(v));
    else {for (const [a, b] of Object.entries(k)) {
        data.set(a, structuredClone(b));
      }}
  },
  list: async ({ prefix, startAfter = "", limit }) =>
    new Map(
      [...data].filter(([k]) => k.startsWith(prefix) && k > startAfter).sort((
        [a],
        [b],
      ) => a.localeCompare(b)).slice(0, limit),
    ),
};
const bucket = {
  get: async (k) => {
    if (storageFailure) throw Error("fixture outage");
    return objects.has(k) ? { text: async () => objects.get(k) } : null;
  },
  put: async (k, v) => {
    if (storageFailure) throw Error("fixture outage");
    objects.set(k, v);
    return { etag: "fixture" };
  },
};
const secrets = {
  reader: crypto.randomUUID(),
  writer: crypto.randomUUID(),
  admin: crypto.randomUUID(),
};
let authority = new ControlService(storage, bucket, secrets);
const server = createServer(async (req, res) => {
  try {
    let body = "";
    for await (const chunk of req) body += chunk;
    const response = await authority.handle(
      new Request(`http://authority.test${req.url}`, {
        method: req.method,
        headers: req.headers,
        ...(body ? { body } : {}),
      }),
    );
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(await response.text());
  } catch {
    res.writeHead(503);
    res.end();
  }
});
await new Promise((resolve) => server.listen(0, "0.0.0.0", resolve));
const port = server.address().port;
const databaseHost = process.platform === "linux"
  ? execFileSync("docker", [
    "inspect",
    container,
    "--format",
    "{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}",
  ], { encoding: "utf8" }).trim()
  : "host.docker.internal";
if (!/^(host\.docker\.internal|[0-9.]+)$/.test(databaseHost)) {
  throw Error("LOCAL_GATEWAY_INVALID");
}
const call = async (path, body) => {
  const r = await fetch(`http://127.0.0.1:${port}${path}`, {
    method: body ? "POST" : "GET",
    headers: { Authorization: `Bearer ${secrets.admin}` },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  return { status: r.status, body: await r.json() };
};
const user = crypto.randomUUID();
const receipt = crypto.randomUUID();
let restoreId;
const vaultIds = [];
try {
  for (
    const [name, value] of [[
      "signalword_control_url",
      `http://${databaseHost}:${port}`,
    ], ["signalword_control_reader", secrets.reader]]
  ) {
    vaultIds.push(
      (await sql(`select vault.create_secret('${value}','${name}');`)).trim(),
    );
  }
  await assert.rejects(
    () => sql("select public.require_safety_authority();"),
    /SAFETY_AUTHORITY_UNAVAILABLE/,
  );
  await call("/gate");
  await call("/quarantine", { backupAt: new Date().toISOString() });
  let snap = (await call("/snapshot")).body;
  assert.equal(
    (await call("/release", {
      restoreId: snap.state.restoreId,
      version: snap.state.version,
      digest: snap.digest,
    })).status,
    200,
  );
  await sql("select public.require_safety_authority();");
  await sql(
    `insert into auth.users(id,aud,role,raw_app_meta_data,raw_user_meta_data,created_at,updated_at) values('${user}','authenticated','authenticated','{}','{}',now(),now()); insert into public.profiles(id,display_name) values('${user}','Restore fixture');`,
  );
  const backup = await docker([
    "pg_dump",
    "-U",
    "postgres",
    "-d",
    "postgres",
    "--data-only",
    "--table=auth.users",
    "--table=public.profiles",
    "--no-owner",
    "--no-privileges",
  ]);
  const backupAt = new Date().toISOString();
  await sql(
    `select public.prepare_journaled_deletion('${user}',extensions.digest('${receipt}','sha256'));`,
  );
  const pending = JSON.parse(
    (await sql(`select public.journal_pending('${user}');`)).trim(),
  );
  storageFailure = true;
  assert.equal((await call("/journal", pending[0])).status, 503);
  await sql(`select public.finish_journaled_deletion('${user}');`);
  assert.equal(
    (await sql(`select count(*) from auth.users where id='${user}';`)).trim(),
    "1",
  );
  authority = new ControlService(storage, bucket, secrets);
  storageFailure = false;
  for (const entry of pending) {
    assert.equal((await call("/journal", entry)).status, 200);
    assert.equal((await call("/journal", entry)).status, 200);
    await sql(`select public.journal_mark_durable('${entry.id}');`);
  }
  await sql(`select public.finish_journaled_deletion('${user}');`);
  assert.equal(
    (await sql(`select count(*) from auth.users where id='${user}';`)).trim(),
    "0",
  );
  await call("/quarantine", { backupAt });
  // Restore only this drill's account backup; remove only its later local receipts.
  await sql(
    `delete from public.pending_deletions where user_id='${user}';delete from public.safety_journal_outbox where user_id='${user}';delete from public.deletion_receipts where receipt_hash=extensions.digest('${receipt}','sha256');\n${backup}`,
  );
  assert.equal(
    (await sql(`select count(*) from auth.users where id='${user}';`)).trim(),
    "1",
  );
  await assert.rejects(
    () => sql("select public.require_safety_authority();"),
    /SAFETY_AUTHORITY_UNAVAILABLE/,
  );
  snap = (await call("/snapshot")).body;
  restoreId = snap.state.restoreId;
  const replay =
    `select public.reconcile_restore_journal('${restoreId}',${snap.state.version},'${snap.digest}','${
      JSON.stringify(snap.entries).replaceAll("'", "''")
    }'::jsonb);`;
  await sql(replay);
  await sql(replay);
  assert.equal(
    (await sql(`select count(*) from auth.users where id='${user}';`)).trim(),
    "0",
  );
  assert.equal(
    (await call("/release", {
      restoreId,
      version: snap.state.version,
      digest: snap.digest,
    })).status,
    200,
  );
  await sql("select public.require_safety_authority();");
  await assert.rejects(
    () => sql(`select public.require_safety_authority('${user}');`),
    /SAFETY_AUTHORITY_UNAVAILABLE/,
  );
  console.log(
    "PASS: account pg_dump/restore, real PostgreSQL HTTP quarantine gate, journal outage/restart, duplicate replay, durable deletion and deleted-subject denial",
  );
} finally {
  await sql(
    `delete from auth.users where id='${user}';delete from public.pending_deletions where user_id='${user}';delete from public.safety_journal_outbox where user_id='${user}';delete from public.deletion_receipts where receipt_hash=extensions.digest('${receipt}','sha256');${
      restoreId
        ? `delete from public.restore_reconciliation_receipts where restore_id='${restoreId}';`
        : ""
    }${
      vaultIds.map((id) => `delete from vault.secrets where id='${id}';`).join(
        "",
      )
    }`,
  );
  await new Promise((resolve) => server.close(resolve));
}
