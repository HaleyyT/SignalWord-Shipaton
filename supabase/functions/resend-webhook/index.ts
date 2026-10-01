import { parseResendWebhook, verifyResendWebhookSignature, type ResendWebhookEvent } from "../_shared/webhook.ts";
import { ApiError, readBodyBytes } from "../_shared/http.ts";

const MAX_WEBHOOK_BYTES = 128 * 1024;

interface WebhookDependencies {
  webhookSecret: string;
  apply(event: ResendWebhookEvent): Promise<boolean>;
}

export function createResendWebhookHandler(dependencies: WebhookDependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
    let rawBody: Uint8Array;
    try {
      // Preserve the exact signed bytes without buffering an unbounded upload.
      rawBody = await readBodyBytes(request, MAX_WEBHOOK_BYTES);
    } catch (error) {
      return new Response(null, { status: error instanceof ApiError ? 413 : 400 });
    }
    const providerEventId = request.headers.get("svix-id");
    const verified = await verifyResendWebhookSignature({
      rawBody,
      messageId: providerEventId,
      timestamp: request.headers.get("svix-timestamp"),
      signature: request.headers.get("svix-signature"),
      secret: dependencies.webhookSecret,
    });
    if (!verified || !providerEventId) return new Response(null, { status: 401 });
    let event: ResendWebhookEvent;
    try { event = parseResendWebhook(rawBody, providerEventId); }
    catch { return new Response(null, { status: 400 }); }
    try {
      await dependencies.apply(event);
      return new Response(null, { status: 202 });
    } catch {
      // A valid receipt must be retried when storage is unavailable.
      return new Response(null, { status: 503, headers: { "Retry-After": "5" } });
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const webhookSecret = Deno.env.get("RESEND_WEBHOOK_SECRET");
  if (!url || !serviceRoleKey || !webhookSecret) throw new Error("Webhook configuration is required");
  const rpcUrl = `${url.replace(/\/$/, "")}/rest/v1/rpc/reconcile_resend_webhook`;
  Deno.serve(createResendWebhookHandler({
    webhookSecret,
    async apply(event) {
      const response = await fetch(rpcUrl, {
        method: "POST",
        signal: AbortSignal.timeout(5000),
        headers: {
          apikey: serviceRoleKey,
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_provider_event_id: event.providerEventId,
          p_provider_message_id: event.providerMessageId,
          p_event_type: event.eventType,
          p_correlation: event.deliveryCorrelation ?? null,
        }),
      });
      if (!response.ok) throw new Error("WEBHOOK_RECONCILIATION_FAILED");
      return await response.json() === true;
    },
  }));
}
