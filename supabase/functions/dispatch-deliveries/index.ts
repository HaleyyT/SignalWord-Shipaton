import { journalFromEnvironment } from "../_shared/safety-journal.ts";
import {
  FakeDeliveryAdapter,
  runContactVerificationWorker,
  runDeliveryWorker,
  type ContactVerificationProviderAdapter,
  type DeliveryProviderAdapter,
  type RuntimeEnvironment,
} from "../_shared/delivery.ts";
import { createContactDataProtection, createDeliveryPayloadCipher } from "../_shared/encryption.ts";
import { createContactVerificationOutbox, createDeliveryOutbox } from "../_shared/outbox.ts";
import { ResendDeliveryAdapter } from "../_shared/resend.ts";

interface DispatchDependencies {
  dispatchSecret: string;
  run(workerId: string): Promise<{ alerts: unknown; confirmations: unknown }>;
}

function secretMatches(actual: string | null, expected: string): boolean {
  const prefix = "Bearer ";
  if (!actual?.startsWith(prefix) || expected.length < 32) return false;
  const left = new TextEncoder().encode(actual.slice(prefix.length));
  const right = new TextEncoder().encode(expected);
  let difference = left.byteLength ^ right.byteLength;
  const length = Math.max(left.byteLength, right.byteLength);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index] ?? 0) ^ (right[index] ?? 0);
  }
  return difference === 0;
}

export function createDispatchHandler(dependencies: DispatchDependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    if (!secretMatches(request.headers.get("Authorization"), dependencies.dispatchSecret)) {
      return Response.json({ error: { code: "AUTH_REQUIRED" } }, {
        status: 401,
        headers: { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" },
      });
    }
    try {
      const result = await dependencies.run(crypto.randomUUID());
      return Response.json(result, { headers: { "Cache-Control": "no-store" } });
    } catch {
      return Response.json({ error: { code: "DISPATCH_FAILED" } }, {
        status: 503,
        headers: { "Cache-Control": "no-store", "Retry-After": "30" },
      });
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const dispatchSecret = Deno.env.get("DISPATCH_SECRET");
  const payloadKey = Deno.env.get("DELIVERY_PAYLOAD_KEY");
  const contactKey = Deno.env.get("DESTINATION_ENCRYPTION_KEY");
  const fingerprintKey = Deno.env.get("DESTINATION_FINGERPRINT_KEY");
  const environment = (Deno.env.get("APP_ENV") ?? "production") as RuntimeEnvironment;
  const providerName = Deno.env.get("DELIVERY_PROVIDER");
  const payloadKeyVersion = Number(Deno.env.get("DELIVERY_PAYLOAD_KEY_VERSION") ?? "1");
  const contactKeyVersion = Number(Deno.env.get("DESTINATION_KEY_VERSION") ?? "1");
  if (!url || !serviceRoleKey || !dispatchSecret || !payloadKey || !contactKey || !fingerprintKey) {
    throw new Error("Dispatch backend and encryption configuration are required");
  }

  let adapter: DeliveryProviderAdapter & ContactVerificationProviderAdapter;
  if (providerName === "resend") {
    const apiKey = Deno.env.get("RESEND_API_KEY");
    const from = Deno.env.get("RESEND_FROM_EMAIL");
    const viewerUrl = Deno.env.get("PUBLIC_VIEWER_BASE_URL");
    const confirmationUrl = Deno.env.get("PUBLIC_CONFIRMATION_BASE_URL");
    if (!apiKey || !from || !viewerUrl || !confirmationUrl) throw new Error("Resend configuration is required");
    adapter = new ResendDeliveryAdapter({
      apiKey,
      from,
      publicViewerBaseUrl: viewerUrl,
      publicConfirmationBaseUrl: confirmationUrl,
      environment,
    });
  } else if (providerName === "fake") {
    adapter = new FakeDeliveryAdapter(environment);
  } else {
    throw new Error("DELIVERY_PROVIDER must be configured");
  }

  const payloadCipher = createDeliveryPayloadCipher(payloadKey, payloadKeyVersion);
  const contactCipher = createContactDataProtection(contactKey, fingerprintKey, contactKeyVersion);
  const database = { url, serviceRoleKey };
  Deno.serve(createDispatchHandler({
    dispatchSecret,
    async run(workerId) {
      // Contact revocation is already atomic in Postgres. A journal outage must
      // not starve other consenting users; the health endpoint reports backlog.
      // The independent gate still blocks claims during restore quarantine.
      await journalFromEnvironment().flush(undefined, false).catch(() => undefined);
      let alerts = { claimed: 0, sent: 0, failed: 0, leaseLost: 0 };
      let confirmations = { claimed: 0, sent: 0, failed: 0, leaseLost: 0 };
      const deadline = Date.now() + 20_000;
      for (let iteration = 0; iteration < 10 && Date.now() < deadline; iteration++) {
      const alertBatch = await runDeliveryWorker({
        workerId,
        outbox: createDeliveryOutbox(database),
        cipher: payloadCipher,
        destinationCipher: { decryptEmail: contactCipher.decryptDestination },
        adapter,
      });
      const contactBatch = await runContactVerificationWorker({
        workerId,
        outbox: createContactVerificationOutbox(database),
        confirmationCipher: { decryptToken: contactCipher.decryptConfirmationToken },
        destinationCipher: { decryptEmail: contactCipher.decryptDestination },
        adapter,
      });
      for (const key of ["claimed", "sent", "failed", "leaseLost"] as const) {
        alerts[key] += alertBatch[key]; confirmations[key] += contactBatch[key];
      }
      if (alertBatch.claimed + contactBatch.claimed === 0) break;
      }
      return { alerts, confirmations };
    },
  }));
}
