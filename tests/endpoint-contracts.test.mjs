import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createUserApiHandler } from "../supabase/functions/user-api/index.ts";
import { createDeliveryPolicy } from "../supabase/functions/_shared/delivery.ts";
const read = (name) =>
  JSON.parse(
    readFileSync(new URL(`../contracts/${name}`, import.meta.url), "utf8"),
  );
const endpoints = read("endpoints.json");
const fixture = (name) => read(`${name}.response.json`);
const user = "00000000-0000-4000-8000-000000000010",
  key = "00000000-0000-4000-8000-000000000030";
function handler() {
  return createUserApiHandler({
    backend: {
      authenticate: async () => ({ id: user }),
      createAlert: async () => fixture("v1/create-alert"),
    },
    lifecycle: {
      profile: async () => fixture("v1/profile"),
      recover: async () => fixture("v1/recovery"),
      saveContact: async () => fixture("v1/contact"),
      getContact: async () => fixture("v1/contact"),
      disableContact: async () => true,
      appendLocation: async () => fixture("v1/append-location"),
      details: async () => fixture("v1/alert-status"),
      resolveAlert: async () => fixture("v1/resolve-alert"),
      deleteData: async () => fixture("v1/delete-data"),
    },
    network: {
      network: async () => fixture("v2/contact-network"),
      save: async () => fixture("v1/contact"),
      recipients: async () => fixture("v2/recipients"),
      create: async () => fixture("v1/create-alert"),
    },
    checkIn: {
      recover: async () => fixture("v2/check-in"),
      change: async () => fixture("v2/check-in"),
    },
    delivery: createDeliveryPolicy("test", "fake"),
    generateToken: () => "a".repeat(43),
    encryptPayload: async () => ({ ciphertext: "fixture", keyVersion: 1 }),
    protectContact: async () => ({
      destinationCiphertext: "fixture",
      destinationFingerprint: "f".repeat(64),
      destinationKeyVersion: 1,
      confirmationPayloadCiphertext: "fixture",
      payloadKeyVersion: 1,
    }),
    now: () => Date.parse("2026-09-28T00:00:00Z"),
    logger: { write() {} },
  });
}
function request(row, authorized = true, body = row.request) {
  return new Request(`https://api.example.test/user-api${row.path}`, {
    method: row.method,
    headers: {
      "Content-Type": "application/json",
      "Idempotency-Key": key,
      "X-Deletion-Receipt": "a".repeat(43),
      ...(authorized ? { Authorization: "Bearer fixture" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
for (const row of endpoints) {
  test(`${row.method} ${row.path}: success contract and unauthenticated denial`, async () => {
    for (
      const field of [
        "auth",
        "identity",
        "error",
        "idempotency",
        "rateLimit",
        "permission",
        "compatibility",
      ]
    ) assert.ok(row[field]);
    const api = handler();
    let response = await api(request(row));
    assert.equal(
      response.status,
      row.status,
      JSON.stringify(await response.clone().json()),
    );
    assert.deepEqual(await response.json(), fixture(row.response));
    response = await api(request(row, false));
    assert.equal(response.status, 401);
    const error = (await response.json()).error;
    assert.equal(error.code, "AUTH_REQUIRED");
    assert.equal(error.retryable, false);
    assert.equal(typeof error.requestId, "string");
  });
  if (row.request) {
    test(`${row.method} ${row.path}: backend-only fields rejected`, async () => {
      const response = await handler()(
        request(row, true, {
          ...row.request,
          userId: user,
          deliveryProvider: "resend",
        }),
      );
      assert.equal(response.status, 400);
      assert.equal((await response.json()).error.code, "INVALID_REQUEST");
    });
  }
}
