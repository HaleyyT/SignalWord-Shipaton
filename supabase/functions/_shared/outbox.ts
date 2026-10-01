import type {
  ClaimedContactVerification,
  ClaimedDelivery,
  ContactVerificationOutbox,
  DeliveryOutbox,
} from "./delivery.ts";

function rpcClient(configuration: { url: string; serviceRoleKey: string }) {
  const baseUrl = configuration.url.replace(/\/$/, "");
  const headers = {
    apikey: configuration.serviceRoleKey,
    Authorization: `Bearer ${configuration.serviceRoleKey}`,
    "Content-Type": "application/json",
  };
  return { baseUrl, headers };
}

export function createDeliveryOutbox(configuration: { url: string; serviceRoleKey: string }): DeliveryOutbox {
  const { baseUrl, headers } = rpcClient(configuration);

  return {
    async claim(workerId, limit) {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/claim_alert_deliveries`, {
        method: "POST", signal: AbortSignal.timeout(5000),
        headers,
        body: JSON.stringify({ p_worker_id: workerId, p_limit: limit }),
      });
      if (!response.ok) throw new Error("DELIVERY_OUTBOX_CLAIM_FAILED");
      const rows = await response.json() as Array<Record<string, unknown>>;
      return rows.map((row): ClaimedDelivery => {
        if (typeof row.delivery_id !== "string" || typeof row.event_id !== "string" ||
          (row.kind !== "test" && row.kind !== "real") ||
          (row.message_type !== "initial" && row.message_type !== "resolved") ||
          (row.provider !== "fake" && row.provider !== "resend") ||
          typeof row.provider_idempotency_key !== "string" ||
          typeof row.payload_ciphertext !== "string" || typeof row.payload_key_version !== "number" ||
          typeof row.destination_ciphertext !== "string" || typeof row.destination_key_version !== "number" ||
          typeof row.attempt_count !== "number") {
          throw new Error("INVALID_DELIVERY_OUTBOX_RESULT");
        }
        return {
          deliveryId: row.delivery_id,
          eventId: row.event_id,
          ...(typeof row.sender_name === "string" ? { senderName: row.sender_name.slice(0, 80) } : {}),
          cause: row.cause === "missed_check_in" ? "missed_check_in" : "user_triggered",
          kind: row.kind,
          messageType: row.message_type,
          provider: row.provider,
          providerIdempotencyKey: row.provider_idempotency_key,
          payloadCiphertext: row.payload_ciphertext,
          payloadKeyVersion: row.payload_key_version,
          destinationCiphertext: row.destination_ciphertext,
          destinationKeyVersion: row.destination_key_version,
          attemptCount: row.attempt_count,
        };
      });
    },

    async finish(deliveryId, workerId, result) {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/finish_alert_delivery`, {
        method: "POST", signal: AbortSignal.timeout(5000),
        headers,
        body: JSON.stringify({
          p_delivery_id: deliveryId,
          p_worker_id: workerId,
          p_succeeded: result.succeeded,
          p_provider_message_id: result.providerMessageId ?? null,
          p_error_code: result.errorCode ?? null,
          p_retryable: result.retryable ?? true,
        }),
      });
      if (!response.ok) throw new Error("DELIVERY_OUTBOX_FINISH_FAILED");
      return await response.json() === true;
    },
  };
}

export function createContactVerificationOutbox(
  configuration: { url: string; serviceRoleKey: string },
): ContactVerificationOutbox {
  const { baseUrl, headers } = rpcClient(configuration);
  return {
    async claim(workerId, limit) {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/claim_contact_verification_deliveries`, {
        method: "POST", signal: AbortSignal.timeout(5000),
        headers,
        body: JSON.stringify({ p_worker_id: workerId, p_limit: limit }),
      });
      if (!response.ok) throw new Error("CONTACT_OUTBOX_CLAIM_FAILED");
      const rows = await response.json() as Array<Record<string, unknown>>;
      return rows.map((row): ClaimedContactVerification => {
        if (typeof row.delivery_id !== "string" || typeof row.contact_id !== "string" ||
          (row.provider !== "fake" && row.provider !== "resend") ||
          typeof row.provider_idempotency_key !== "string" ||
          typeof row.payload_ciphertext !== "string" || typeof row.payload_key_version !== "number" ||
          typeof row.destination_ciphertext !== "string" || typeof row.destination_key_version !== "number" ||
          typeof row.attempt_count !== "number") {
          throw new Error("INVALID_CONTACT_OUTBOX_RESULT");
        }
        return {
          deliveryId: row.delivery_id,
          contactId: row.contact_id,
          provider: row.provider,
          providerIdempotencyKey: row.provider_idempotency_key,
          payloadCiphertext: row.payload_ciphertext,
          payloadKeyVersion: row.payload_key_version,
          destinationCiphertext: row.destination_ciphertext,
          destinationKeyVersion: row.destination_key_version,
          attemptCount: row.attempt_count,
        };
      });
    },
    async finish(deliveryId, workerId, result) {
      const response = await fetch(`${baseUrl}/rest/v1/rpc/finish_contact_verification_delivery`, {
        method: "POST", signal: AbortSignal.timeout(5000),
        headers,
        body: JSON.stringify({
          p_delivery_id: deliveryId,
          p_worker_id: workerId,
          p_succeeded: result.succeeded,
          p_provider_message_id: result.providerMessageId ?? null,
          p_error_code: result.errorCode ?? null,
          p_retryable: result.retryable ?? true,
        }),
      });
      if (!response.ok) throw new Error("CONTACT_OUTBOX_FINISH_FAILED");
      return await response.json() === true;
    },
  };
}
