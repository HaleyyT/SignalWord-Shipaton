const SIGNATURE_TOLERANCE_SECONDS = 300;

function decodeBase64(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const binary = atob(value);
    return Uint8Array.from(binary, (character) => character.charCodeAt(0));
  } catch {
    return null;
  }
}

function constantTimeEqual(left: Uint8Array, right: Uint8Array): boolean {
  let difference = left.byteLength ^ right.byteLength;
  const length = Math.max(left.byteLength, right.byteLength);
  for (let index = 0; index < length; index += 1) {
    difference |= (left[index % Math.max(left.byteLength, 1)] ?? 0) ^
      (right[index % Math.max(right.byteLength, 1)] ?? 0);
  }
  return difference === 0;
}

function webhookSecretBytes(secret: string): Uint8Array<ArrayBuffer> {
  const encoded = secret.startsWith("whsec_") ? secret.slice(6) : secret;
  const bytes = decodeBase64(encoded);
  if (!bytes || bytes.byteLength < 16) throw new Error("Invalid webhook secret");
  return bytes;
}

export async function verifyResendWebhookSignature(input: {
  rawBody: Uint8Array;
  messageId: string | null;
  timestamp: string | null;
  signature: string | null;
  secret: string;
  nowSeconds?: number;
}): Promise<boolean> {
  if (!input.messageId || !/^[A-Za-z0-9_-]{1,200}$/.test(input.messageId) || !input.timestamp || !input.signature) return false;
  const timestamp = Number(input.timestamp);
  const now = input.nowSeconds ?? Math.floor(Date.now() / 1000);
  if (!Number.isSafeInteger(timestamp) || Math.abs(now - timestamp) > SIGNATURE_TOLERANCE_SECONDS) return false;
  let secret: Uint8Array<ArrayBuffer>;
  try {
    secret = webhookSecretBytes(input.secret);
  } catch {
    return false;
  }
  const signed = new Uint8Array(
    new TextEncoder().encode(`${input.messageId}.${input.timestamp}.`).byteLength + input.rawBody.byteLength,
  );
  const prefix = new TextEncoder().encode(`${input.messageId}.${input.timestamp}.`);
  signed.set(prefix);
  signed.set(input.rawBody, prefix.byteLength);
  const key = await crypto.subtle.importKey("raw", secret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const expected = new Uint8Array(await crypto.subtle.sign("HMAC", key, signed));
  return input.signature.split(/\s+/).some((candidate) => {
    const match = /^v1,([A-Za-z0-9+/=]+)$/.exec(candidate);
    const actual = match ? decodeBase64(match[1]) : null;
    return actual ? constantTimeEqual(expected, actual) : false;
  });
}

export interface ResendWebhookEvent {
  providerEventId: string;
  deliveryCorrelation?: string;
  providerMessageId: string;
  eventType: "sent" | "delivered" | "bounced" | "complained" | "failed" | "delivery_delayed";
}

export function parseResendWebhook(rawBody: Uint8Array, providerEventId: string): ResendWebhookEvent {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(rawBody));
  } catch {
    throw new Error("INVALID_WEBHOOK_PAYLOAD");
  }
  if (!value || typeof value !== "object") throw new Error("INVALID_WEBHOOK_PAYLOAD");
  const payload = value as { type?: unknown; data?: { email_id?: unknown; tags?: Record<string, unknown> } };
  const typeMap: Record<string, ResendWebhookEvent["eventType"]> = {
    "email.sent": "sent",
    "email.delivered": "delivered",
    "email.bounced": "bounced",
    "email.complained": "complained",
    "email.failed": "failed",
    "email.delivery_delayed": "delivery_delayed",
  };
  const eventType = typeof payload.type === "string" ? typeMap[payload.type] : undefined;
  if (!eventType || typeof payload.data?.email_id !== "string" || payload.data.email_id.length < 1 || payload.data.email_id.length > 200) {
    throw new Error("INVALID_WEBHOOK_PAYLOAD");
  }
  const correlation = payload.data.tags?.signalword_delivery;
  if (correlation !== undefined && (typeof correlation !== "string" || !/^[a-f0-9]{64}$/.test(correlation))) {
    throw new Error("INVALID_WEBHOOK_CORRELATION");
  }
  return { providerEventId, providerMessageId: payload.data.email_id, eventType,
    ...(typeof correlation === "string" ? { deliveryCorrelation: correlation } : {}) };

}
