import test from "node:test";
import assert from "node:assert/strict";
import { parseCheckIn } from "../supabase/functions/_shared/check-in.ts";
import { parseUserResponse } from "../supabase/functions/_shared/response-contracts.ts";
import { renderAlertEmail } from "../supabase/functions/_shared/resend.ts";
import { createUserApiHandler } from "../supabase/functions/user-api/index.ts";
import { createDeliveryPolicy } from "../supabase/functions/_shared/delivery.ts";
import { readFileSync } from "node:fs";
const id = "a1000000-0000-4000-8000-000000000001";
const fixture = JSON.parse(
  readFileSync("contracts/v2/check-in.response.json", "utf8"),
);
test("timer accepts only defined durations and action fields", () => {
  for (const minutes of [15, 30, 60]) {
    assert.equal(parseCheckIn({ action: "start", minutes }).minutes, minutes);
  }
  for (
    const value of [
      null,
      [],
      { action: "start", minutes: 0 },
      { action: "extend", minutes: 15 },
      { action: "cancel", timerId: id, minutes: 15 },
      { action: "start", minutes: 15, deadline: "tomorrow" },
      { action: "start", minutes: 15, timerId: id },
    ]
  ) assert.throws(() => parseCheckIn(value));
});
test("timer projection removes capabilities and rejects unsupported state", () => {
  assert.deepEqual(
    parseUserResponse("checkIn", { ...fixture, recipient_payloads: "private" }),
    fixture,
  );
  assert.throws(() =>
    parseUserResponse("checkIn", { ...fixture, state: "safe" })
  );
  assert.equal(parseUserResponse("checkIn", null), null);
});
test("timer API stores only hashed and encrypted capabilities and uses verified user identity", async () => {
  let count = 0, captured;
  const handler = createUserApiHandler({
    network: {},
    checkIn: {
      change: async (...args) => {
        captured = args;
        return fixture;
      },
    },
    backend: { authenticate: async () => ({ id }) },
    lifecycle: {},
    delivery: createDeliveryPolicy("test", "fake"),
    now: () => Date.now(),
    generateToken: () => String(++count).repeat(43),
    encryptPayload: async (token) => ({
      ciphertext: "encrypted-" + token,
      keyVersion: 1,
    }),
    logger: { write() {} },
  });
  const response = await handler(
    new Request("https://example.test/user-api/v2/check-in", {
      method: "POST",
      headers: {
        Authorization: "Bearer fixture",
        "Idempotency-Key": id,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ action: "start", minutes: 15 }),
    }),
  );
  assert.equal(response.status, 200);
  assert.equal(captured[0], id);
  assert.equal(captured[2], id);
  assert.equal(captured[5].length, 3);
  assert.equal(new Set(captured[5].map((x) => x.hash)).size, 3);
  assert.ok(
    captured[5].every((x) => !("token" in x) && /^[a-f0-9]{64}$/.test(x.hash)),
  );
});
test("missed check-in content is honest and TEST takes precedence", () => {
  const delivery = {
    senderName: "<Alex>",
    kind: "real",
    messageType: "initial",
    cause: "missed_check_in",
  };
  const email = renderAlertEmail(delivery, "https://example.test/e/token");
  assert.equal(email.subject, "SignalWord missed check-in");
  assert.match(email.text, /does not confirm danger/);
  assert.ok(email.html.includes("&lt;Alex&gt;"));
  assert.ok(!email.text.includes("started a SignalWord safety alert"));
  assert.match(
    renderAlertEmail(
      { ...delivery, kind: "test" },
      "https://example.test/e/token",
    ).subject,
    /TEST/,
  );
});
