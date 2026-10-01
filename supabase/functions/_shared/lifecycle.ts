import type { SafetyJournal } from "./safety-journal.ts";
import { ApiError } from "./http.ts";

export interface ContactProjection {
  contactId: string;
  name: string;
  channel: "email";
  status: "pending" | "confirmed" | "disabled";
  confirmationExpiresAt?: string;
}

export interface AlertStatusProjection {
  eventId: string;
  kind: "test" | "real";
  state: "pending" | "active" | "resolved" | "expired";
  triggeredAt: string;
  resolvedAt?: string;
  delivery: "queued" | "sent" | "delivered" | "failed" | "unknown";
  acknowledgedAt?: string;
  resolutionDelivery?: "queued" | "sent" | "delivered" | "failed" | "unknown";
  latestLocationAt?: string;
}

export interface LifecycleGateway {
  profile(userId: string, jwt: string, displayName?: string): Promise<unknown>;
  recover(userId: string, jwt: string, key?: string): Promise<unknown>;
  details(userId: string, eventId: string, jwt: string): Promise<unknown>;
  saveContact(input: {
    userId: string;
    name: string;
    destinationCiphertext: string;
    destinationFingerprint: string;
    destinationKeyVersion: number;
    confirmationTokenHashHex: string;
    confirmationPayloadCiphertext: string;
    payloadKeyVersion: number;
    provider: "fake" | "resend";
  }, jwt: string): Promise<ContactProjection>;
  getContact(userId: string, jwt: string): Promise<ContactProjection | null>;
  disableContact(userId: string, contactId: string, jwt: string): Promise<boolean>;
  appendLocation(userId: string, eventId: string, location: unknown, jwt: string): Promise<{ accepted: boolean; receivedAt: string }>;
  getAlertStatus(userId: string, eventId: string, jwt: string): Promise<AlertStatusProjection | null>;
  resolveAlert(userId: string, eventId: string, jwt: string): Promise<{ eventId: string; state: "resolved"; resolvedAt: string }>;
  deleteData(userId: string, jwt: string, receiptHashHex: string): Promise<{ deletionId: string }>;
  confirmContact(tokenHashHex: string): Promise<boolean>;
  withdrawContact(tokenHashHex: string): Promise<boolean>;
}

type Row = Record<string, unknown>;

function contactProjection(row: Row): ContactProjection {
  if (typeof row.contact_id !== "string" || typeof row.contact_name !== "string" ||
    row.contact_channel !== "email" || !["pending", "confirmed", "disabled"].includes(String(row.contact_status))) {
    throw new ApiError(503, "SERVICE_UNAVAILABLE", "Contact service returned an invalid result.", true);
  }
  return {
    contactId: row.contact_id,
    name: row.contact_name,
    channel: "email",
    status: row.contact_status as ContactProjection["status"],
    ...(typeof row.confirmation_expires_at === "string" ? { confirmationExpiresAt: row.confirmation_expires_at } : {}),
  };
}

export function createLifecycleGateway(configuration: { url: string; anonKey: string; serviceRoleKey?: string; journal?: SafetyJournal }): LifecycleGateway {
  const baseUrl = configuration.url.replace(/\/$/, "");
  const headers = (authorization: string, apiKey = configuration.anonKey) => ({
    apikey: apiKey,
    Authorization: authorization,
    "Content-Type": "application/json",
  });
  const rpc = async (name: string, body: unknown, authorization: string, message: string, apiKey = configuration.anonKey): Promise<unknown> => {
    let response: Response;
    try {
      response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
        method: "POST", signal: AbortSignal.timeout(5000), headers: headers(authorization, apiKey), body: JSON.stringify(body),
      });
    } catch {
      throw new ApiError(503, "SERVICE_UNAVAILABLE", `${message} is temporarily unavailable.`, true);
    }
    if (!response.ok) {
      const payload = await response.json().catch(() => ({})) as { message?: unknown };
      if (response.status === 401 || response.status === 403 || payload.message === "NOT_AUTHORIZED") {
        throw new ApiError(401, "AUTH_REQUIRED", "Authentication is required.");
      }
      if (payload.message === "EVENT_NOT_FOUND") throw new ApiError(404, "NOT_FOUND", "Alert not found.");
      if (payload.message === "EVENT_NOT_ACTIVE") throw new ApiError(409, "EVENT_NOT_ACTIVE", "This alert is no longer active.");
      if (payload.message === "RATE_LIMITED") {
        throw new ApiError(429, "RATE_LIMITED", "Too many contact setup requests. Try again later.", true, 3600);
      }
      throw new ApiError(503, "SERVICE_UNAVAILABLE", `${message} is temporarily unavailable.`, true);
    }
    return await response.json();
  };

  return {
    async profile(userId, jwt, displayName) {
      return await rpc("signalword_profile", {p_user_id: userId, p_display_name: displayName ?? null}, `Bearer ${jwt}`, "Profile");
    },
    async recover(userId, jwt, key) {
      return await rpc("recover_alerts", {p_user_id: userId, p_idempotency_key: key ?? null}, `Bearer ${jwt}`, "Recovery");
    },
    async details(userId, eventId, jwt) {
      return await rpc("alert_details", {p_user_id: userId, p_event_id: eventId}, `Bearer ${jwt}`, "Alert status");
    },
    async saveContact(input, _jwt) {
      // The HTTP handler authenticates first and supplies the verified user ID.
      // Only this write uses service credentials: clients cannot mint consent tokens.
      const serviceKey = configuration.serviceRoleKey;
      if (!serviceKey) throw new ApiError(503, "SERVICE_UNAVAILABLE", "Contact setup is unavailable.", true);
      const rows = await rpc("create_or_replace_contact", {
        p_user_id: input.userId,
        p_name: input.name,
        p_channel: "email",
        p_destination_ciphertext: input.destinationCiphertext,
        p_destination_fingerprint: input.destinationFingerprint,
        p_destination_key_version: input.destinationKeyVersion,
        p_confirmation_token_hash: `\\x${input.confirmationTokenHashHex}`,
        p_confirmation_payload_ciphertext: input.confirmationPayloadCiphertext,
        p_payload_key_version: input.payloadKeyVersion,
        p_delivery_provider: input.provider,
      }, `Bearer ${serviceKey}`, "Contact setup", serviceKey) as Row[];
      await configuration.journal?.flush(input.userId);
      return contactProjection(rows[0] ?? {});
    },
    async getContact(userId, jwt) {
      const rows = await rpc("get_my_contact", { p_user_id: userId }, `Bearer ${jwt}`, "Contact status") as Row[];
      return rows[0] ? contactProjection(rows[0]) : null;
    },
    async disableContact(userId, contactId, jwt) {
      const disabled = await rpc("disable_contact", { p_user_id: userId, p_contact_id: contactId }, `Bearer ${jwt}`, "Contact update") === true;
      await configuration.journal?.flush(userId);
      return disabled;
    },
    async appendLocation(userId, eventId, location, jwt) {
      const rows = await rpc("append_alert_location", {
        p_user_id: userId, p_event_id: eventId, p_location: location,
      }, `Bearer ${jwt}`, "Location update") as Row[];
      const row = rows[0];
      if (!row || typeof row.accepted !== "boolean" || typeof row.received_at !== "string") {
        throw new ApiError(503, "SERVICE_UNAVAILABLE", "Location update returned an invalid result.", true);
      }
      return { accepted: row.accepted, receivedAt: row.received_at };
    },
    async getAlertStatus(userId, eventId, jwt) {
      const rows = await rpc("get_alert_status", { p_user_id: userId, p_event_id: eventId }, `Bearer ${jwt}`, "Alert status") as Row[];
      const row = rows[0];
      if (!row) return null;
      if (typeof row.event_id !== "string" || !["test", "real"].includes(String(row.event_kind)) ||
        !["pending", "active", "resolved", "expired"].includes(String(row.event_state)) ||
        typeof row.triggered_at !== "string" || !["queued", "sent", "delivered", "failed"].includes(String(row.delivery_status))) {
        throw new ApiError(503, "SERVICE_UNAVAILABLE", "Alert status returned an invalid result.", true);
      }
      return {
        eventId: row.event_id,
        kind: row.event_kind as AlertStatusProjection["kind"],
        state: row.event_state as AlertStatusProjection["state"],
        triggeredAt: row.triggered_at,
        delivery: row.delivery_status as AlertStatusProjection["delivery"],
        ...(typeof row.resolved_at === "string" ? { resolvedAt: row.resolved_at } : {}),
        ...(typeof row.latest_location_at === "string" ? { latestLocationAt: row.latest_location_at } : {}),
      };
    },
    async resolveAlert(userId, eventId, jwt) {
      const rows = await rpc("resolve_alert", { p_user_id: userId, p_event_id: eventId }, `Bearer ${jwt}`, "Alert resolution") as Row[];
      const row = rows[0];
      if (!row || typeof row.event_id !== "string" || row.event_state !== "resolved" || typeof row.event_resolved_at !== "string") {
        throw new ApiError(503, "SERVICE_UNAVAILABLE", "Alert resolution returned an invalid result.", true);
      }
      return { eventId: row.event_id, state: "resolved", resolvedAt: row.event_resolved_at };
    },
    async deleteData(userId, jwt, receiptHashHex) {
      const serviceKey = configuration.serviceRoleKey;
      if (!serviceKey || !configuration.journal) throw new ApiError(503, "SERVICE_UNAVAILABLE", "Deletion recovery is unavailable.", true);
      const deletionId = await rpc("prepare_journaled_deletion", { p_user_id: userId, p_receipt_hash: `\\x${receiptHashHex}` }, `Bearer ${serviceKey}`, "Data deletion", serviceKey);
      await configuration.journal.flush(userId);
      const completed = await rpc("find_deletion_receipt", { p_receipt_hash: `\\x${receiptHashHex}` }, `Bearer ${serviceKey}`, "Deletion status", serviceKey);
      if (completed !== deletionId) throw new ApiError(503, "SERVICE_UNAVAILABLE", "Deletion is still pending.", true);
      if (typeof deletionId !== "string") throw new ApiError(503, "SERVICE_UNAVAILABLE", "Data deletion returned an invalid result.", true);
      return { deletionId };
    },
    async confirmContact(tokenHashHex) {
      return await rpc("confirm_contact", { p_token_hash: `\\x${tokenHashHex}` }, `Bearer ${configuration.anonKey}`, "Contact confirmation") === true;
    },
    async withdrawContact(tokenHashHex) {
      const serviceKey = configuration.serviceRoleKey;
      if (!serviceKey || !configuration.journal) throw new ApiError(503, "SERVICE_UNAVAILABLE", "Withdrawal recovery is unavailable.", true);
      const owner = await rpc("withdrawal_journal_owner", { p_token_hash: `\\x${tokenHashHex}` }, `Bearer ${serviceKey}`, "Contact withdrawal", serviceKey);
      if (typeof owner !== "string") return false;
      const withdrawn = await rpc("withdraw_contact", { p_token_hash: `\\x${tokenHashHex}` }, `Bearer ${configuration.anonKey}`, "Contact withdrawal") === true;
      await configuration.journal.flush(owner);
      return withdrawn;
    },
  };
}
