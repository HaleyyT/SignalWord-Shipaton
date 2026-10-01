import test from "node:test";
import assert from "node:assert/strict";
import { createSafetyJournal } from "../supabase/functions/_shared/safety-journal.ts";
import { createLifecycleGateway } from "../supabase/functions/_shared/lifecycle.ts";
const config = {
  url: "https://db.example.test",
  serviceRoleKey: "service-fixture",
  controlUrl: "https://control.example.test",
  writerKey: "w".repeat(32),
};
const entry = {
  id: crypto.randomUUID(),
  userId: crypto.randomUUID(),
  kind: "delete",
};

test("journal response loss leaves entry pending and a retry completes in order", async (t) => {
  let pending = true, first = true;
  const calls = [];
  t.mock.method(globalThis, "fetch", async (url, options) => {
    const route = new URL(url).pathname.split("/").at(-1);
    calls.push(route);
    if (route === "journal_pending") {
      return Response.json(pending ? [entry] : []);
    }
    if (route === "journal") {
      if (first) {
        first = false;
        throw Error("response lost");
      }
      return Response.json({ durable: true });
    }
    if (route === "journal_mark_durable") pending = false;
    return new Response(null, {status: 204});
  });
  const journal = createSafetyJournal(config);
  await assert.rejects(
    () => journal.flush(entry.userId),
    (e) => e.status === 503,
  );
  assert.equal(pending, true);
  assert.equal(calls.includes("finish_journaled_deletion"), false);
  calls.length = 0;
  await journal.flush(entry.userId);
  assert.deepEqual(calls, [
    "journal_pending",
    "journal",
    "journal_mark_durable",
    "finish_journaled_deletion",
    "journal_pending",
  ]);
});

test("unacknowledged durability and missing configuration fail closed", async (t) => {
  let marked = false;
  t.mock.method(globalThis, "fetch", async (url) => {
    if (url.endsWith("journal_pending")) return Response.json([entry]);
    if (url.endsWith("/journal")) return Response.json({ durable: false });
    marked = true;
    return new Response(null, {status: 204});
  });
  await assert.rejects(() => createSafetyJournal(config).flush());
  assert.equal(marked, false);
  await assert.rejects(() =>
    createSafetyJournal({ ...config, writerKey: "" }).flush()
  );
});

test("deletion HTTP result requires both durable flush and completed receipt", async (t) => {
  let flushed = false, complete = false;
  t.mock.method(globalThis, "fetch", async (url) => {
    if (url.endsWith("prepare_journaled_deletion")) {
      return Response.json(entry.id);
    }
    assert.equal(flushed, true);
    return Response.json(complete ? entry.id : null);
  });
  const gateway = createLifecycleGateway({
    ...config,
    anonKey: "anon",
    journal: {
      flush: async () => {
        flushed = true;
      },
    },
  });
  await assert.rejects(() =>
    gateway.deleteData(entry.userId, "jwt", "a".repeat(64))
  );
  complete = true;
  assert.deepEqual(
    await gateway.deleteData(entry.userId, "jwt", "a".repeat(64)),
    { deletionId: entry.id },
  );
});
