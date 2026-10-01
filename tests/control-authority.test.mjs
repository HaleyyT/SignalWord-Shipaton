import test from "node:test";
import assert from "node:assert/strict";
import { ControlService } from "../infrastructure/control/service.mjs";
const secrets = {
  reader: "r".repeat(32),
  writer: "w".repeat(32),
  admin: "a".repeat(32),
};
function fixture() {
  const data = new Map(), objects = new Map();
  let fail = false;
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
      if (fail) throw Error();
      return objects.has(k) ? { text: async () => objects.get(k) } : null;
    },
    put: async (k, v) => {
      if (fail) throw Error();
      objects.set(k, v);
      return { etag: "fixture" };
    },
  };
  let service = new ControlService(storage, bucket, secrets);
  const call = (path, body, key = "admin", subject) =>
    service.handle(
      new Request("https://authority.test" + path, {
        method: body ? "POST" : "GET",
        headers: {
          Authorization: `Bearer ${secrets[key]}`,
          ...(subject
            ? {
              "X-SignalWord-Subject": subject,
              "X-SignalWord-Issued-At": String(
                Math.ceil(Date.now() / 1000) + 1,
              ),
            }
            : {}),
        },
        ...(body ? { body: JSON.stringify(body) } : {}),
      }),
    );
  return {
    call,
    data,
    objects,
    setFailure: (v) => fail = v,
    restart: () => {
      service = new ControlService(storage, bucket, secrets);
    },
  };
}
const entry = {
  id: "11111111-1111-4111-8111-111111111111",
  userId: "22222222-2222-4222-8222-222222222222",
  kind: "delete",
};
test("authority starts quarantined and only a complete matching reconciliation can open it", async () => {
  const f = fixture();
  assert.equal((await f.call("/gate", null, "reader")).status, 503);
  assert.equal(
    (await f.call("/quarantine", { backupAt: "2000-01-01" })).status,
    409,
  );
  await f.call("/quarantine", { backupAt: new Date().toISOString() });
  const s = await (await f.call("/snapshot")).json();
  assert.equal(
    (await f.call("/release", {
      ...s.state,
      digest: "wrong",
      version: s.state.version,
    })).status,
    409,
  );
  assert.equal(
    (await f.call("/release", {
      restoreId: s.state.restoreId,
      version: s.state.version,
      digest: s.digest,
    })).status,
    200,
  );
  assert.equal((await f.call("/gate", null, "reader")).status, 200);
});
test("journal outage, restart, duplicate append and lost completion are recoverable", async () => {
  const f = fixture();
  f.setFailure(true);
  assert.equal((await f.call("/journal", entry, "writer")).status, 503);
  assert.equal((await f.call("/snapshot")).status, 503);
  f.restart();
  f.setFailure(false);
  assert.equal((await f.call("/journal", entry, "writer")).status, 200);
  assert.equal((await f.call("/journal", entry, "writer")).status, 200);
  assert.equal(f.objects.size, 1);
  assert.equal(
    (await f.call("/journal", { ...entry, userId: entry.id }, "writer")).status,
    409,
  );
});
test("deleted identity stays denied after release and a newer journal invalidates release proof", async () => {
  const f = fixture();
  await f.call("/gate", null, "reader");
  await f.call("/quarantine", { backupAt: new Date().toISOString() });
  const old = await (await f.call("/snapshot")).json();
  await f.call("/journal", entry, "writer");
  assert.equal(
    (await f.call("/release", {
      restoreId: old.state.restoreId,
      version: old.state.version,
      digest: old.digest,
    })).status,
    409,
  );
  const fresh = await (await f.call("/snapshot")).json();
  await f.call("/release", {
    restoreId: fresh.state.restoreId,
    version: fresh.state.version,
    digest: fresh.digest,
  });
  assert.equal(
    (await f.call("/gate", null, "reader", entry.userId)).status,
    503,
  );
  assert.equal((await f.call("/gate", null, "reader", entry.id)).status, 200);
});
test("writer cannot release quarantine or leak arbitrary personal fields into journal", async () => {
  const f = fixture();
  assert.equal((await f.call("/release", {}, "writer")).status, 404);
  assert.equal(
    (await f.call(
      "/journal",
      { ...entry, email: "private@example.test" },
      "writer",
    )).status,
    503,
  );
  assert.equal(f.objects.size, 0);
});

test("journal read failure and missing archive object prevent releasing quarantine", async () => {
  const f = fixture();
  await f.call("/gate", null, "reader");
  await f.call("/quarantine", { backupAt: new Date().toISOString() });
  await f.call("/journal", entry, "writer");
  const snapshot = await (await f.call("/snapshot")).json();
  f.objects.clear();
  assert.equal((await f.call("/snapshot")).status, 503);
  assert.equal(
    (await f.call("/release", {
      restoreId: snapshot.state.restoreId,
      version: snapshot.state.version,
      digest: snapshot.digest,
    })).status,
    503,
  );
});

test("pre-restore access tokens are denied after quarantine is released", async () => {
  const f = fixture();
  await f.call("/gate", null, "reader");
  await f.call("/quarantine", { backupAt: new Date().toISOString() });
  const snapshot = await (await f.call("/snapshot")).json();
  await f.call("/release", {
    restoreId: snapshot.state.restoreId,
    version: snapshot.state.version,
    digest: snapshot.digest,
  });
  const service = new ControlService(
    { get: async (k) => f.data.get(k) },
    null,
    secrets,
  );
  const response = await service.handle(
    new Request("https://authority.test/gate", {
      headers: {
        Authorization: `Bearer ${secrets.reader}`,
        "X-SignalWord-Subject": entry.id,
        "X-SignalWord-Issued-At": "1",
      },
    }),
  );
  assert.equal(response.status, 503);
});
