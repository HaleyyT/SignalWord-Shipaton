import test from "node:test";
import assert from "node:assert/strict";
import { createUserApiHandler } from "../supabase/functions/user-api/index.ts";
import { parseUserResponse } from "../supabase/functions/_shared/response-contracts.ts";
import { createDeliveryPolicy } from "../supabase/functions/_shared/delivery.ts";
import { createContactNetworkGateway } from "../supabase/functions/_shared/contact-network.ts";

const user = "81000000-0000-4000-8000-000000000001";
const event = "83000000-0000-4000-8000-000000000001";
const now = Date.parse("2026-09-28T00:00:00Z");
function handler(
  network,
  backend = { authenticate: async () => ({ id: user }) },
) {
  let counter = 0;
  return createUserApiHandler({
    network,
    backend,
    lifecycle: {},
    delivery: createDeliveryPolicy("test", "fake"),
    now: () => now,
    generateToken: () => String(++counter).repeat(43),
    encryptPayload: async (token) => ({
      ciphertext: `encrypted-${token}`,
      keyVersion: 1,
    }),
    protectContact: async () => ({
      destinationCiphertext: "encrypted-destination",
      destinationFingerprint: "fingerprint",
      destinationKeyVersion: 1,
      confirmationPayloadCiphertext: "encrypted-invite",
      payloadKeyVersion: 1,
    }),
    logger: { write() {} },
  });
}
function request(path, method = "GET", body) {
  return new Request("https://example.test/user-api" + path, {
    method,
    headers: {
      Authorization: "Bearer fixture-token",
      "Content-Type": "application/json",
      "Idempotency-Key": event,
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
}
for (const kind of ["test", "real"]) {
  test(`v2 preserves ${kind} classification and creates three private capabilities`, async () => {
    let captured;
    const api = handler({
      create: async (...args) => {
        captured = args;
        return {
          eventId: event,
          state: "active",
          delivery: "queued",
          serverTriggeredAt: new Date(now).toISOString(),
          reused: false,
        };
      },
    });
    const response = await api(
      request("/v2/alerts", "POST", {
        kind,
        triggerMethod: "manual",
        clientTriggeredAt: new Date(now).toISOString(),
      }),
    );
    assert.equal(response.status, 201);
    assert.equal(captured[0].kind, kind);
    assert.equal(captured[1], user);
    assert.equal(new Set(captured[4].map((p) => p.token)).size, 3);
    const body = await response.text();
    assert.ok(!body.includes("encrypted-"));
    assert.ok(!body.includes("111111111111111111"));
  });
}
test("network requests authenticate before side effects", async () => {
  let called = false;
  const api = handler({
    network: async () => {
      called = true;
    },
  }, {
    authenticate: async () => {
      throw new Error("rejected");
    },
  });
  assert.notEqual((await api(request("/v2/contact-network"))).status, 200);
  assert.equal(called, false);
});
test("routing rejects malformed primary, policy and unknown fields", async () => {
  for (
    const body of [{ primary: "another-user" }, { policy: "police" }, {
      policy: "everyone",
      secret: "x",
    }, []]
  ) {
    const api = handler({
      network: async () => {
        assert.fail("invalid input must not reach database");
      },
    });
    assert.equal(
      (await api(request("/v2/contact-network", "PUT", body))).status,
      400,
    );
  }
});
test("contact network projection removes private database fields", () => {
  assert.deepEqual(
    parseUserResponse("contactNetwork", {
      policy: "everyone",
      contacts: [{
        contactId: user,
        name: "Sam",
        channel: "email",
        status: "confirmed",
        primary: true,
        destination: "private",
      }],
      secret: "private",
    }),
    {
      policy: "everyone",
      contacts: [{
        contactId: user,
        name: "Sam",
        channel: "email",
        status: "confirmed",
        primary: true,
      }],
    },
  );
});
test("recipient projection rejects excessive recipients and private fields", () => {
  const progress = {
    contactId: user,
    name: "Sam",
    revoked: false,
    scheduledAt: new Date(now).toISOString(),
    delivery: "unknown",
    secret: "private",
  };
  assert.equal(
    parseUserResponse("recipients", [progress])[0].secret,
    undefined,
  );
  assert.throws(() => parseUserResponse("recipients", Array(4).fill(progress)));
  assert.throws(() =>
    parseUserResponse("recipients", [{
      ...progress,
      delivery: "police-notified",
    }])
  );
});
test("network read uses caller JWT while contact consent writes use server credentials", async () => {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return Response.json(
      url.endsWith("contact_network")
        ? { policy: "everyone", contacts: [] }
        : [{
          contact_id: user,
          contact_name: "Sam",
          contact_channel: "email",
          contact_status: "pending",
        }],
    );
  };
  try {
    const gateway = createContactNetworkGateway({
      url: "https://example.invalid",
      anonKey: "public-fixture",
      serviceRoleKey: "server-fixture",
    });
    await gateway.network(user, "caller-fixture");
    await gateway.save({ p_user_id: user });
    assert.equal(
      calls[0].options.headers.Authorization,
      "Bearer caller-fixture",
    );
    assert.equal(
      calls[1].options.headers.Authorization,
      "Bearer server-fixture",
    );
    assert.equal(JSON.parse(calls[0].options.body).p_user_id, user);
  } finally {
    globalThis.fetch = original;
  }
});
