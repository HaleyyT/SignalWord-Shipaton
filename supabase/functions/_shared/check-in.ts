import { ApiError } from "./http.ts";
export interface CheckInGateway {
  recover(userId: string, jwt: string, command?: string): Promise<unknown>;
  change(
    userId: string,
    jwt: string,
    command: string,
    input: CheckInInput,
    provider: string,
    payloads: unknown[],
  ): Promise<unknown>;
}
export interface CheckInInput {
  action: "start" | "extend" | "check_in" | "cancel";
  timerId?: string;
  minutes?: number;
}
const uuid =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
export function parseCheckIn(value: unknown): CheckInInput {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiError(400, "INVALID_REQUEST", "Invalid timer request.");
  }
  const input = value as CheckInInput;
  if (
    Object.keys(input).some((k) =>
      !["action", "timerId", "minutes"].includes(k)
    ) ||
    !["start", "extend", "check_in", "cancel"].includes(input.action) ||
    (input.action !== "start" &&
      (!input.timerId || !uuid.test(input.timerId))) ||
    (input.action === "start" && input.timerId !== undefined) ||
    (["start", "extend"].includes(input.action)
      ? ![15, 30, 60].includes(input.minutes ?? 0)
      : input.minutes !== undefined)
  ) {
    throw new ApiError(
      400,
      "INVALID_REQUEST",
      "Choose a supported timer action and duration.",
    );
  }
  return input;
}
export function createCheckInGateway(
  config: { url: string; anonKey: string; serviceRoleKey: string },
): CheckInGateway {
  async function rpc(name: string, body: unknown, jwt: string, privileged = false) {
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
        "Timer status is unconfirmed. Reconcile before retrying.",
        true,
      );
    }
    const value = await response.json().catch(() => null);
    if (!response.ok) {
      if (
        [
          "TIMER_ALREADY_ACTIVE",
          "TIMER_NOT_FOUND",
          "IDEMPOTENCY_CONFLICT",
          "IDEMPOTENCY_EXPIRED",
          "CONTACT_NOT_CONFIRMED",
        ].includes(value?.message)
      ) {
        throw new ApiError(
          409,
          value.message,
          "Refresh timer and contact status before trying again.",
        );
      }
      if (value?.message === "RATE_LIMITED") {
        throw new ApiError(
          429,
          "RATE_LIMITED",
          "Too many timer changes. Try again later.",
          true,
          3600,
        );
      }
      if ([401, 403].includes(response.status)) {
        throw new ApiError(401, "AUTH_REQUIRED", "Authentication required.");
      }
      throw new ApiError(
        503,
        "SERVICE_UNAVAILABLE",
        "Timer status is unconfirmed. Reconcile before retrying.",
        true,
      );
    }
    return value;
  }
  return {
    recover: (userId, jwt, command) =>
      rpc("recover_check_in", {
        p_user_id: userId,
        p_command_id: command ?? null,
      }, jwt),
    change: (userId, jwt, command, input, provider, payloads) =>
      rpc("gateway_change_check_in", {
        p_user_id: userId,
        p_command_id: command,
        p_action: input.action,
        p_timer_id: input.timerId ?? null,
        p_minutes: input.minutes ?? null,
        p_provider: provider,
        p_payloads: payloads,
      }, config.serviceRoleKey, true),
  };
}
