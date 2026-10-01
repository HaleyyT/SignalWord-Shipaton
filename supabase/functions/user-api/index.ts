import { journalFromEnvironment } from "../_shared/safety-journal.ts";
import { createCheckInGateway, parseCheckIn, type CheckInGateway } from "../_shared/check-in.ts";
import { createContactNetworkGateway, type ContactNetworkGateway } from "../_shared/contact-network.ts";
import { parseUserResponse, type ResponseContract } from "../_shared/response-contracts.ts";
import { wakeDispatch } from "../_shared/dispatch-wakeup.ts";
import { createDeliveryPolicy, type DeliveryCreationPolicy, type RuntimeEnvironment } from "../_shared/delivery.ts";
import { createContactDataProtection, createDeliveryPayloadCipher } from "../_shared/encryption.ts";
import { ApiError, asApiError, bearerToken, errorResponse, jsonResponse, readJson, requestId } from "../_shared/http.ts";
import { createLifecycleGateway, type LifecycleGateway } from "../_shared/lifecycle.ts";
import { structuredLogger, writeSafely, type SafeLogger } from "../_shared/logging.ts";
import { createBackendGateway, type BackendGateway } from "../_shared/supabase.ts";
import { generateViewerToken, sha256Hex } from "../_shared/tokens.ts";
import { parseCreateAlert, parseIdempotencyKey } from "../_shared/validation.ts";

export interface UserApiDependencies {
  checkIn?: CheckInGateway;
  network?: ContactNetworkGateway;
  wake?: () => void;
  backend: BackendGateway;
  lifecycle: LifecycleGateway;
  delivery: DeliveryCreationPolicy;
  encryptPayload: (viewerToken: string) => Promise<{ ciphertext: string; keyVersion: number }>;
  logger: SafeLogger;
  now: () => number;
  generateToken: () => string;
  protectContact: (email: string, confirmationToken: string) => Promise<{
    destinationCiphertext: string;
    destinationFingerprint: string;
    destinationKeyVersion: number;
    confirmationPayloadCiphertext: string;
    payloadKeyVersion: number;
  }>;
  exposeServerTiming?: boolean;
}

const RESPONSE_HEADERS = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function timingHeaders(enabled: boolean | undefined, timings: Record<string, number>): Record<string, string> {
  if (!enabled) return {};
  const values = Object.entries(timings)
    .filter(([, duration]) => Number.isFinite(duration) && duration >= 0)
    .map(([name, duration]) => `${name};dur=${Math.round(duration * 10) / 10}`);
  return values.length > 0 ? { "Server-Timing": values.join(", ") } : {};
}

function contactInput(value: unknown): { name: string; email: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(400, "INVALID_REQUEST", "Contact must be an object.");
  }
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some((key) => !["name", "email"].includes(key)) ||
    typeof body.name !== "string" || typeof body.email !== "string") {
    throw new ApiError(400, "INVALID_REQUEST", "Contact name and email are required.");
  }
  const name = body.name.trim();
  const email = body.email.trim().toLowerCase();
  if (name.length < 1 || name.length > 80 || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new ApiError(400, "INVALID_REQUEST", "Contact name or email is invalid.");
  }
  return { name, email };
}

export function createUserApiHandler(dependencies: UserApiDependencies) {
  return async (request: Request): Promise<Response> => {
    const startedAt = dependencies.now();
    const id = requestId(request);
    let status = 500;
    let operation: "profile" | "contact" | "check-in" | "contact-network" | "alert" | "account-deletion" | "other" = "other";
    let code: string | undefined;
    let reused: boolean | undefined;
    const timings: Record<string, number> = {};
    let exposeTimingForRequest = false;

    try {
      const path = new URL(request.url).pathname.replace(/\/+$/, "");
      operation = path.endsWith("/v1/profile") ? "profile"
        : path.endsWith("/v1/contact") || path.includes("/contacts") ? "contact"
        : path.includes("/check-in") ? "check-in"
        : path.endsWith("/contact-network") ? "contact-network"
        : path.includes("/alerts") ? "alert"
        : path.endsWith("/v1/data") ? "account-deletion" : "other";
      exposeTimingForRequest = request.method === "POST" && path.endsWith("/v2/alerts");
      const jwt = bearerToken(request);
      const authStartedAt = dependencies.now();
      const user = await dependencies.backend.authenticate(jwt);
      timings.auth_session = Math.max(0, dependencies.now() - authStartedAt);
      let result: unknown;
      let contract: ResponseContract;

      if (path.includes("/v2/") && !dependencies.network) {
        throw new ApiError(503, "SERVICE_UNAVAILABLE", "Contact network is unavailable.", true);
      }
      if (["GET","POST"].includes(request.method) && path.endsWith("/v2/check-in")) {
        if (!dependencies.checkIn) throw new ApiError(503,"SERVICE_UNAVAILABLE","Timers are unavailable.",true);
        contract="checkIn";
        if (request.method === "GET") {
          const command=new URL(request.url).searchParams.get("command") ?? undefined;
          if (command && !UUID_PATTERN.test(command)) throw new ApiError(400,"INVALID_REQUEST","Invalid command.");
          result=await dependencies.checkIn.recover(user.id,jwt,command);
        } else {
          const input=parseCheckIn(await readJson(request));
          const command=parseIdempotencyKey(request.headers.get("Idempotency-Key"));
          const payloads=[];
          if (input.action === "start") {
            dependencies.delivery.assertAvailable("real");
            for (let i=0;i<3;i++) {
              const token=dependencies.generateToken();
              payloads.push({hash:await sha256Hex(token),...await dependencies.encryptPayload(token)});
            }
          }
          result=await dependencies.checkIn.change(user.id,jwt,command,input,dependencies.delivery.provider,payloads);
        }
        status=200;
      } else if (["GET", "PUT"].includes(request.method) && path.endsWith("/v2/contact-network")) {
        let primary: string | undefined;
        let policy: string | undefined;
        if (request.method === "PUT") {
          const body = await readJson(request) as Record<string, unknown>;
          if (!body || typeof body !== "object" || Array.isArray(body) ||
              Object.keys(body).some(k => !["primary", "policy"].includes(k)) ||
              (body.primary !== undefined && (typeof body.primary !== "string" || !UUID_PATTERN.test(body.primary))) ||
              (body.policy !== undefined && !["everyone", "primary_then_others"].includes(String(body.policy)))) {
            throw new ApiError(400, "INVALID_REQUEST", "Invalid contact routing settings.");
          }
          primary=body.primary as string | undefined; policy=body.policy as string | undefined;
        }
        result=await dependencies.network!.network(user.id,jwt,primary,policy);
        contract="contactNetwork"; status=200;
      } else if (request.method === "GET" && /\/v2\/alerts\/[0-9a-f-]+\/recipients$/i.test(path)) {
        const eventId=path.split("/").at(-2)!;
        if (!UUID_PATTERN.test(eventId)) throw new ApiError(400,"INVALID_REQUEST","Invalid event.");
        result=await dependencies.network!.recipients(user.id,eventId,jwt);
        contract="recipients"; status=200;
      } else if (request.method === "POST" && /\/v2\/contacts(?:\/[0-9a-f-]+)?$/i.test(path)) {
        dependencies.delivery.assertAvailable("test");
        const contactId=path.endsWith("/contacts") ? null : path.split("/").at(-1)!;
        if (contactId && !UUID_PATTERN.test(contactId)) throw new ApiError(400,"INVALID_REQUEST","Invalid contact.");
        const input=contactInput(await readJson(request));
        const token=dependencies.generateToken();
        const protectedData=await dependencies.protectContact(input.email,token);
        result=await dependencies.network!.save({p_user_id:user.id,p_contact_id:contactId,p_name:input.name,p_channel:"email",
          p_destination_ciphertext:protectedData.destinationCiphertext,p_destination_fingerprint:protectedData.destinationFingerprint,
          p_destination_key_version:protectedData.destinationKeyVersion,p_confirmation_token_hash:`\\x${await sha256Hex(token)}`,
          p_confirmation_payload_ciphertext:protectedData.confirmationPayloadCiphertext,p_payload_key_version:protectedData.payloadKeyVersion,
          p_delivery_provider:dependencies.delivery.provider});
        contract="contact"; status=202;
      } else if (request.method === "POST" && path.endsWith("/v2/alerts")) {
        const key=parseIdempotencyKey(request.headers.get("Idempotency-Key"));
        const input=parseCreateAlert(await readJson(request),dependencies.now());
        dependencies.delivery.assertAvailable(input.kind);
        const preparationStartedAt = dependencies.now();
        const recipients=[];
        for (let i=0;i<3;i++) {
          const token=dependencies.generateToken();
          recipients.push({token,...await dependencies.encryptPayload(token)});
        }
        timings.preparation = Math.max(0, dependencies.now() - preparationStartedAt);
        const databaseStartedAt = dependencies.now();
        result=await dependencies.network!.create(input,user.id,key,dependencies.delivery.provider,recipients,jwt);
        timings.database = Math.max(0, dependencies.now() - databaseStartedAt);
        contract="createAlert"; reused=(result as {reused:boolean}).reused; status=reused ? 200 : 201;
      } else if (["GET", "PUT"].includes(request.method) && path.endsWith("/v1/profile")) {
        let displayName: string | undefined;
        if (request.method === "PUT") {
          const body = await readJson(request) as { displayName?: unknown };
          if (!body || Array.isArray(body) || Object.keys(body).some(key => key !== "displayName") || typeof body?.displayName !== "string" || !body.displayName.trim() || body.displayName.trim().length > 80) {
            throw new ApiError(400, "INVALID_REQUEST", "Enter a name between 1 and 80 characters.");
          }
          displayName = body.displayName.trim();
        }
        contract = "profile";
        result = await dependencies.lifecycle.profile(user.id, jwt, displayName);
        status = 200;
      } else if (request.method === "GET" && path.endsWith("/v1/alerts/recovery")) {
        const key = new URL(request.url).searchParams.get("key") ?? undefined;
        if (key && !UUID_PATTERN.test(key)) throw new ApiError(400, "INVALID_REQUEST", "Invalid command key.");
        contract = "recovery";
        result = await dependencies.lifecycle.recover(user.id, jwt, key);
        status = 200;
      } else if (request.method === "POST" && path.endsWith("/v1/alerts")) {
        const idempotencyKey = parseIdempotencyKey(request.headers.get("Idempotency-Key"));
        const input = parseCreateAlert(await readJson(request), dependencies.now());
        dependencies.delivery.assertAvailable(input.kind);
        const viewerToken = dependencies.generateToken();
        const encrypted = await dependencies.encryptPayload(viewerToken);
        contract = "createAlert";
        result = await dependencies.backend.createAlert(input, user.id, idempotencyKey, {
          viewerToken,
          provider: dependencies.delivery.provider,
          payloadCiphertext: encrypted.ciphertext,
          payloadKeyVersion: encrypted.keyVersion,
        }, jwt);
        reused = (result as { reused: boolean }).reused;
        status = reused ? 200 : 201;
      } else if (request.method === "POST" && path.endsWith("/v1/contacts")) {
        dependencies.delivery.assertAvailable("test");
        const input = contactInput(await readJson(request));
        const confirmationToken = dependencies.generateToken();
        const protectedData = await dependencies.protectContact(input.email, confirmationToken);
        contract = "contact";
        result = await dependencies.lifecycle.saveContact({
          userId: user.id,
          name: input.name,
          ...protectedData,
          confirmationTokenHashHex: await sha256Hex(confirmationToken),
          provider: dependencies.delivery.provider,
        }, jwt);
        status = 202;
      } else if (request.method === "GET" && path.endsWith("/v1/contact")) {
        contract = "contact";
        result = await dependencies.lifecycle.getContact(user.id, jwt);
        if (result === null) throw new ApiError(404, "NOT_FOUND", "No trusted contact is configured.");
        status = 200;
      } else {
        const contactMatch = /\/v1\/contacts\/([0-9a-f-]+)$/i.exec(path);
        const locationMatch = /\/v1\/alerts\/([0-9a-f-]+)\/locations$/i.exec(path);
        const resolveMatch = /\/v1\/alerts\/([0-9a-f-]+)\/resolve$/i.exec(path);
        const statusMatch = /\/v1\/alerts\/([0-9a-f-]+)$/i.exec(path);
        if (request.method === "DELETE" && contactMatch && UUID_PATTERN.test(contactMatch[1])) {
          contract = "disableContact";
          result = { disabled: await dependencies.lifecycle.disableContact(user.id, contactMatch[1], jwt) };
          status = 200;
        } else if (request.method === "POST" && locationMatch && UUID_PATTERN.test(locationMatch[1])) {
          const body = await readJson(request) as { location?: unknown };
          if (!body || Array.isArray(body) || Object.keys(body).some(key => key !== "location")) {
            throw new ApiError(400, "INVALID_REQUEST", "Only location is accepted.");
          }
          const parsed = parseCreateAlert({
            kind: "real", triggerMethod: "manual",
            clientTriggeredAt: new Date(dependencies.now()).toISOString(), location: body?.location,
          }, dependencies.now());
          if (!parsed.location) throw new ApiError(400, "INVALID_REQUEST", "A current valid location is required.");
          contract = "appendLocation";
          result = await dependencies.lifecycle.appendLocation(user.id, locationMatch[1], parsed.location, jwt);
          status = 202;
        } else if (request.method === "POST" && resolveMatch && UUID_PATTERN.test(resolveMatch[1])) {
          contract = "resolveAlert";
          result = await dependencies.lifecycle.resolveAlert(user.id, resolveMatch[1], jwt);
          status = 200;
        } else if (request.method === "GET" && statusMatch && UUID_PATTERN.test(statusMatch[1])) {
          contract = "alertStatus";
          result = await (dependencies.lifecycle.details ? dependencies.lifecycle.details(user.id, statusMatch[1], jwt) : dependencies.lifecycle.getAlertStatus(user.id, statusMatch[1], jwt));
          if (result === null) throw new ApiError(404, "NOT_FOUND", "Alert not found.");
          status = 200;
        } else if (request.method === "DELETE" && path.endsWith("/v1/data")) {
          const receiptToken = request.headers.get("X-Deletion-Receipt") ?? "";
          if (!/^[A-Za-z0-9_-]{43}$/.test(receiptToken)) {
            throw new ApiError(400, "INVALID_REQUEST", "A deletion receipt is required.");
          }
          contract = "deleteData";
          result = await dependencies.lifecycle.deleteData(user.id, jwt, await sha256Hex(receiptToken));
          status = 200;
        } else {
          throw new ApiError(404, "NOT_FOUND", "Route not found.");
        }
      }
      if (request.method === "POST") {
        // The committed outbox and scheduled sweep remain authoritative.
        try { dependencies.wake?.(); } catch { /* Best-effort wakeup cannot undo acceptance. */ }
      }
      timings.app = Math.max(0, dependencies.now() - startedAt);
      return jsonResponse(parseUserResponse(contract, result), status, {
        ...RESPONSE_HEADERS,
        ...timingHeaders(dependencies.exposeServerTiming && exposeTimingForRequest, timings),
        "X-Request-ID": id,
      });
    } catch (caught) {
      const error = asApiError(caught);
      status = error.status;
      code = error.code;
      timings.app = Math.max(0, dependencies.now() - startedAt);
      return errorResponse(error, id, {
        ...RESPONSE_HEADERS,
        ...timingHeaders(dependencies.exposeServerTiming && exposeTimingForRequest, timings),
        "X-Request-ID": id,
      });
    } finally {
      writeSafely(dependencies.logger, {
        requestId: id,
        route: "user-api",
        operation,
        method: request.method,
        status,
        durationMs: Math.max(0, dependencies.now() - startedAt),
        ...(code ? { code } : {}),
        ...(reused === undefined ? {} : { reused }),
      });
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const environment = (Deno.env.get("APP_ENV") ?? "production") as RuntimeEnvironment;
  const configuredProvider = Deno.env.get("DELIVERY_PROVIDER");
  const provider = configuredProvider === "fake" || configuredProvider === "resend" ? configuredProvider : "none";
  const encodedKey = Deno.env.get("DELIVERY_PAYLOAD_KEY");
  const contactEncryptionKey = Deno.env.get("DESTINATION_ENCRYPTION_KEY");
  const contactFingerprintKey = Deno.env.get("DESTINATION_FINGERPRINT_KEY");
  const keyVersion = Number(Deno.env.get("DELIVERY_PAYLOAD_KEY_VERSION") ?? "1");
  const destinationKeyVersion = Number(Deno.env.get("DESTINATION_KEY_VERSION") ?? "1");
  if (!url || !anonKey || !serviceRoleKey || !encodedKey || !contactEncryptionKey || !contactFingerprintKey) {
    throw new Error("Backend URL, anonymous key, delivery key, and contact protection keys are required");
  }
  const cipher = createDeliveryPayloadCipher(encodedKey, keyVersion);
  const contactProtection = createContactDataProtection(
    contactEncryptionKey, contactFingerprintKey, destinationKeyVersion,
  );
  Deno.serve(createUserApiHandler({
    wake: () => {
      const task = wakeDispatch(url, Deno.env.get("DISPATCH_SECRET") ?? "");
      const runtime = (globalThis as unknown as { EdgeRuntime?: { waitUntil(task: Promise<void>): void } }).EdgeRuntime;
      runtime?.waitUntil(task);
    },
    backend: createBackendGateway({ url, anonKey, serviceRoleKey }),
    lifecycle: createLifecycleGateway({ url, anonKey, serviceRoleKey, journal: journalFromEnvironment() }),
    network: createContactNetworkGateway({ url, anonKey, serviceRoleKey, journal: journalFromEnvironment() }),
    checkIn: createCheckInGateway({ url, anonKey, serviceRoleKey }),
    delivery: createDeliveryPolicy(environment, provider),
    encryptPayload: async (viewerToken) => ({
      ciphertext: await cipher.encrypt(viewerToken),
      keyVersion: cipher.keyVersion,
    }),
    logger: structuredLogger,
    now: () => Date.now(),
    generateToken: generateViewerToken,
    protectContact: async (email, confirmationToken) => ({
      destinationCiphertext: await contactProtection.encryptDestination(email),
      destinationFingerprint: await contactProtection.fingerprintDestination(email),
      destinationKeyVersion: contactProtection.keyVersion,
      confirmationPayloadCiphertext: await contactProtection.encryptConfirmationToken(confirmationToken),
      payloadKeyVersion: contactProtection.keyVersion,
    }),
    exposeServerTiming: environment === "development",
  }));
}
