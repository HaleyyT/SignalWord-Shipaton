import type { SafetyJournal } from "./safety-journal.ts";
import { ApiError } from "./http.ts";
import type { CreateAlertInput } from "./validation.ts";

export interface ContactNetworkGateway {
  network(
    userId: string,
    jwt: string,
    primary?: string,
    policy?: string,
  ): Promise<unknown>;
  save(input: Record<string, unknown>): Promise<unknown>;
  recipients(userId: string, eventId: string, jwt: string): Promise<unknown>;
  create(
    input: CreateAlertInput,
    userId: string,
    key: string,
    provider: string,
    recipients: Array<
      { token: string; ciphertext: string; keyVersion: number }
    >,
    jwt: string,
  ): Promise<unknown>;
}

export function createContactNetworkGateway(
  config: { url: string; anonKey: string; serviceRoleKey: string; journal?: SafetyJournal },
): ContactNetworkGateway {
  async function rpc(
    name: string,
    body: unknown,
    jwt: string,
    privileged = false,
  ): Promise<unknown> {
    let response: Response;
    try {
      response = await fetch(
        `${config.url.replace(/\/$/, "")}/rest/v1/rpc/${name}`,
        {
          method: "POST",
          signal: AbortSignal.timeout(5000),
          headers: {
            apikey: privileged ? config.serviceRoleKey : config.anonKey,
            Authorization: `Bearer ${jwt}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify(body),
        },
      );
    } catch {
      throw new ApiError(
        503,
        "SERVICE_UNAVAILABLE",
        "Contact network is temporarily unavailable.",
        true,
      );
    }
    const result = await response.json().catch(() => null);
    if (!response.ok) {
      const message = result?.message;
      if (
        [
          "CONTACT_LIMIT",
          "CONTACT_NOT_CONFIRMED",
          "CONTACT_NOT_FOUND",
          "INVALID_POLICY",
        ].includes(message)
      ) {
        throw new ApiError(
          409,
          message,
          "Refresh your contacts and review the selected primary contact.",
        );
      }
      if (message === "RATE_LIMITED") {
        throw new ApiError(429, "RATE_LIMITED", "Try again later.", true, 3600);
      }
      if ([401, 403].includes(response.status)) {
        throw new ApiError(401, "AUTH_REQUIRED", "Authentication is required.");
      }
      throw new ApiError(
        503,
        "SERVICE_UNAVAILABLE",
        "Contact network is temporarily unavailable.",
        true,
      );
    }
    return result;
  }
  return {
    network: (userId, jwt, primary, policy) =>
      rpc("contact_network", {
        p_user_id: userId,
        p_primary: primary ?? null,
        p_policy: policy ?? null,
      }, jwt),
    recipients: (userId, eventId, jwt) =>
      rpc(
        "recipient_progress",
        { p_user_id: userId, p_event_id: eventId },
        jwt,
      ),
    async save(input) {
      const rows = await rpc(
        "save_network_contact",
        input,
        config.serviceRoleKey,
        true,
      ) as Record<string, unknown>[];
      await config.journal?.flush(String(input.p_user_id));
      const row = rows?.[0];
      return {
        contactId: row?.contact_id,
        name: row?.contact_name,
        channel: row?.contact_channel,
        status: row?.contact_status,
        confirmationExpiresAt: row?.confirmation_expires_at,
      };
    },
    async create(input, userId, key, provider, recipients, jwt) {
      const rows = await rpc("gateway_create_routed_alert", {
        p_user_id: userId,
        p_idempotency_key: key,
        p_kind: input.kind,
        p_trigger_method: input.triggerMethod,
        p_delivery_provider: provider,
        p_recipients: recipients,
        p_location: input.location ?? null,
        p_client_triggered_at: input.clientTriggeredAt,
      }, config.serviceRoleKey, true) as Record<string, unknown>[];
      const row = rows?.[0];
      return {
        eventId: row?.event_id,
        state: row?.event_state,
        delivery: row?.delivery_status,
        serverTriggeredAt: row?.server_triggered_at,
        reused: row?.reused,
      };
    },
  };
}
