import test from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { createDeletionStatusHandler } from "../supabase/functions/deletion-status/index.ts";
import { createPublicEventHandler } from "../supabase/functions/public-event/index.ts";
import { createContactConfirmHandler } from "../supabase/functions/contact-confirm/index.ts";
const rows = JSON.parse(
  readFileSync(new URL("../contracts/system-endpoints.json", import.meta.url)),
);
test("every deployed system function and authority route has an explicit contract and behavioral suite", () => {
  assert.equal(rows.length, 13);
  for (const row of rows) {
    for (
      const key of [
        "requestSchema",
        "responseSchema",
        "auth",
        "identity",
        "idempotency",
        "rateLimit",
        "errorSchema",
        "permission",
        "compatibility",
      ]
    ) assert.ok(row[key], `${row.service}: ${key}`);
    assert.ok(existsSync(new URL(`../${row.behavioralTest}`, import.meta.url)));
  }
  assert.deepEqual([...new Set(rows.map((r) => r.service))].sort(), [
    "contact-confirm",
    "deletion-status",
    "dispatch-deliveries",
    "operational-health",
    "public-event",
    "resend-webhook",
    "safety-authority",
  ]);
});
test("public boolean contracts do not disclose backend fields and require explicit actions", async () => {
  const token = "a".repeat(43), logger = { write() {} }, now = () => 0;
  const publicAPI = createPublicEventHandler({
    backend: { acknowledge: async () => true },
    logger,
    now,
  });
  let r = await publicAPI(
    new Request(`https://fixture.test/v1/public/events/${token}`, {
      method: "POST",
      headers: { "X-SignalWord-Action": "acknowledge" },
    }),
  );
  assert.deepEqual(await r.json(), { acknowledged: true });
  r = await publicAPI(
    new Request(`https://fixture.test/v1/public/events/${token}`, {
      method: "POST",
    }),
  );
  assert.equal(r.status, 400);
  const contact = createContactConfirmHandler({
    lifecycle: {
      confirmContact: async () => true,
      withdrawContact: async () => true,
    },
    logger,
    now,
  });
  for (
    const [headers, expected] of [[{}, { confirmed: true }], [{
      "X-SignalWord-Action": "withdraw",
    }, { withdrawn: true }]]
  ) {
    r = await contact(
      new Request(`https://fixture.test/v1/contacts/confirm/${token}`, {
        method: "POST",
        headers,
      }),
    );
    assert.deepEqual(await r.json(), expected);
  }
  r = await contact(
    new Request(`https://fixture.test/v1/contacts/confirm/${token}`),
  );
  assert.equal(r.status, 405);
  const deletion = createDeletionStatusHandler(async () => null);
  r = await deletion(
    new Request("https://fixture.test/v1/deletions/status", {
      headers: { "X-Deletion-Receipt": token },
    }),
  );
  assert.deepEqual(await r.json(), { deleted: false });
});
