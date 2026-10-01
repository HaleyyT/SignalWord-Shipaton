import { ApiError } from "./http.ts";
import type { AlertKind } from "./validation.ts";

export type RuntimeEnvironment = "development" | "test" | "production";
export type DeliveryProviderName = "fake" | "resend";

export interface DeliveryCreationPolicy {
  provider: DeliveryProviderName;
  assertAvailable(kind: AlertKind): void;
}

export function createDeliveryPolicy(
  environment: RuntimeEnvironment,
  configuredProvider: DeliveryProviderName | "none",
): DeliveryCreationPolicy {
  if (environment !== "development" && environment !== "test" && environment !== "production") {
    throw new Error("APP_ENV must be development, test, or production");
  }
  if (configuredProvider === "fake" && environment === "production") {
    throw new Error("Fake delivery cannot be enabled in production");
  }
  return {
    provider: configuredProvider === "none" ? "fake" : configuredProvider,
    assertAvailable(kind) {
      if (configuredProvider === "none") {
        throw new ApiError(
          503,
          "SERVICE_UNAVAILABLE",
          kind === "real" ? "Real alerts are unavailable until delivery is configured." : "Delivery is unavailable.",
          true,
        );
      }
    },
  };
}

export interface ClaimedDelivery {
  senderName?: string;
  cause?: "user_triggered" | "missed_check_in";
  deliveryId: string;
  eventId: string;
  kind: AlertKind;
  messageType: "initial" | "resolved";
  provider: DeliveryProviderName;
  providerIdempotencyKey: string;
  payloadCiphertext: string;
  payloadKeyVersion: number;
  destinationCiphertext: string;
  destinationKeyVersion: number;
  attemptCount: number;
}

export interface DeliveryOutbox {
  claim(workerId: string, limit: number): Promise<ClaimedDelivery[]>;
  finish(deliveryId: string, workerId: string, result: {
    succeeded: boolean;
    providerMessageId?: string;
    errorCode?: string;
    retryable?: boolean;
  }): Promise<boolean>;
}

export interface DeliveryPayloadCipher {
  decrypt(ciphertext: string, keyVersion: number): Promise<{ viewerToken: string }>;
}

export interface DeliveryDestinationCipher {
  decryptEmail(ciphertext: string, keyVersion: number): Promise<string>;
}

export interface ProviderDelivery {
  senderName?: string;
  cause?: "user_triggered" | "missed_check_in";
  eventId: string;
  kind: AlertKind;
  messageType: "initial" | "resolved";
  recipient: string;
  viewerToken: string;
  idempotencyKey: string;
}

export interface DeliveryProviderAdapter {
  readonly provider?: DeliveryProviderName;
  send(delivery: ProviderDelivery): Promise<{ providerMessageId: string }>;
}

export interface ClaimedContactVerification {
  deliveryId: string;
  contactId: string;
  provider: DeliveryProviderName;
  providerIdempotencyKey: string;
  payloadCiphertext: string;
  payloadKeyVersion: number;
  destinationCiphertext: string;
  destinationKeyVersion: number;
  attemptCount: number;
}

export interface ContactVerificationOutbox {
  claim(workerId: string, limit: number): Promise<ClaimedContactVerification[]>;
  finish(deliveryId: string, workerId: string, result: {
    succeeded: boolean;
    providerMessageId?: string;
    errorCode?: string;
    retryable?: boolean;
  }): Promise<boolean>;
}

export interface ContactConfirmationCipher {
  decryptToken(ciphertext: string, keyVersion: number): Promise<string>;
}

export interface ContactVerificationProviderAdapter {
  readonly provider?: DeliveryProviderName;
  sendVerification(delivery: {
    contactId: string;
    recipient: string;
    confirmationToken: string;
    idempotencyKey: string;
  }): Promise<{ providerMessageId: string }>;
}

export class DeliveryAttemptError extends Error {
  readonly retryable: boolean;
  readonly safeCode: string;

  constructor(safeCode: string, retryable: boolean) {
    super(safeCode);
    this.name = "DeliveryAttemptError";
    this.safeCode = safeCode;
    this.retryable = retryable;
  }
}

export class FakeDeliveryAdapter implements DeliveryProviderAdapter, ContactVerificationProviderAdapter {
  readonly provider = "fake" as const;
  constructor(environment: RuntimeEnvironment) {
    if (environment === "production") throw new Error("Fake delivery cannot run in production");
  }

  async send(delivery: { idempotencyKey: string }): Promise<{ providerMessageId: string }> {
    return { providerMessageId: `fake/${delivery.idempotencyKey}` };
  }

  async sendVerification(delivery: { idempotencyKey: string }): Promise<{ providerMessageId: string }> {
    return { providerMessageId: `fake/${delivery.idempotencyKey}` };
  }
}

export async function runDeliveryWorker(dependencies: {
  workerId: string;
  outbox: DeliveryOutbox;
  cipher: DeliveryPayloadCipher;
  destinationCipher?: DeliveryDestinationCipher;
  adapter: DeliveryProviderAdapter;
  limit?: number;
}): Promise<{ claimed: number; sent: number; failed: number; leaseLost: number }> {
  const deliveries = await dependencies.outbox.claim(dependencies.workerId, 1);
  let sent = 0;
  let failed = 0;
  let leaseLost = 0;

  for (const delivery of deliveries) {
    let providerAccepted = false;
    try {
      if (dependencies.adapter.provider && dependencies.adapter.provider !== delivery.provider) {
        throw new DeliveryAttemptError("PROVIDER_MISMATCH", false);
      }
      const payload = await dependencies.cipher.decrypt(delivery.payloadCiphertext, delivery.payloadKeyVersion);
      if (!/^[A-Za-z0-9_-]{43}$/.test(payload.viewerToken)) throw new Error("INVALID_DELIVERY_PAYLOAD");
      if (!dependencies.destinationCipher) throw new DeliveryAttemptError("DESTINATION_DECRYPTION_UNAVAILABLE", false);
      const recipient = await dependencies.destinationCipher.decryptEmail(
        delivery.destinationCiphertext,
        delivery.destinationKeyVersion,
      );
      const result = await dependencies.adapter.send({
        senderName: delivery.senderName,
        cause: delivery.cause,
        eventId: delivery.eventId,
        kind: delivery.kind,
        messageType: delivery.messageType,
        recipient,
        viewerToken: payload.viewerToken,
        idempotencyKey: delivery.providerIdempotencyKey,
      });
      providerAccepted = true;
      const finalized = await dependencies.outbox.finish(delivery.deliveryId, dependencies.workerId, {
        succeeded: true,
        providerMessageId: result.providerMessageId,
      });
      if (!finalized) {
        leaseLost += 1;
        continue;
      }
      sent += 1;
    } catch (error) {
      if (providerAccepted) {
        leaseLost += 1;
        continue;
      }
      const attempt = error instanceof DeliveryAttemptError
        ? error
        : new DeliveryAttemptError("DELIVERY_ATTEMPT_FAILED", true);
      const finalized = await dependencies.outbox.finish(delivery.deliveryId, dependencies.workerId, {
        succeeded: false,
        errorCode: attempt.safeCode,
        retryable: attempt.retryable,
      });
      if (finalized) failed += 1;
      else leaseLost += 1;
    }
  }

  return { claimed: deliveries.length, sent, failed, leaseLost };
}

export async function runContactVerificationWorker(dependencies: {
  workerId: string;
  outbox: ContactVerificationOutbox;
  confirmationCipher: ContactConfirmationCipher;
  destinationCipher: DeliveryDestinationCipher;
  adapter: ContactVerificationProviderAdapter;
  limit?: number;
}): Promise<{ claimed: number; sent: number; failed: number; leaseLost: number }> {
  const deliveries = await dependencies.outbox.claim(dependencies.workerId, 1);
  let sent = 0;
  let failed = 0;
  let leaseLost = 0;

  for (const delivery of deliveries) {
    let providerAccepted = false;
    try {
      if (dependencies.adapter.provider && dependencies.adapter.provider !== delivery.provider) {
        throw new DeliveryAttemptError("PROVIDER_MISMATCH", false);
      }
      const [confirmationToken, recipient] = await Promise.all([
        dependencies.confirmationCipher.decryptToken(delivery.payloadCiphertext, delivery.payloadKeyVersion),
        dependencies.destinationCipher.decryptEmail(
          delivery.destinationCiphertext,
          delivery.destinationKeyVersion,
        ),
      ]);
      if (!/^[A-Za-z0-9_-]{43}$/.test(confirmationToken)) {
        throw new DeliveryAttemptError("INVALID_CONFIRMATION_PAYLOAD", false);
      }
      const result = await dependencies.adapter.sendVerification({
        contactId: delivery.contactId,
        recipient,
        confirmationToken,
        idempotencyKey: delivery.providerIdempotencyKey,
      });
      providerAccepted = true;
      const finalized = await dependencies.outbox.finish(delivery.deliveryId, dependencies.workerId, {
        succeeded: true,
        providerMessageId: result.providerMessageId,
      });
      if (finalized) sent += 1;
      else leaseLost += 1;
    } catch (error) {
      if (providerAccepted) {
        leaseLost += 1;
        continue;
      }
      const attempt = error instanceof DeliveryAttemptError
        ? error
        : new DeliveryAttemptError("DELIVERY_ATTEMPT_FAILED", true);
      const finalized = await dependencies.outbox.finish(delivery.deliveryId, dependencies.workerId, {
        succeeded: false,
        errorCode: attempt.safeCode,
        retryable: attempt.retryable,
      });
      if (finalized) failed += 1;
      else leaseLost += 1;
    }
  }

  return { claimed: deliveries.length, sent, failed, leaseLost };
}
