import { journalFromEnvironment } from "../_shared/safety-journal.ts";
import { ApiError, asApiError, errorResponse, jsonResponse, requestId } from "../_shared/http.ts";
import { createLifecycleGateway, type LifecycleGateway } from "../_shared/lifecycle.ts";
import { structuredLogger, writeSafely, type SafeLogger } from "../_shared/logging.ts";
import { sha256Hex } from "../_shared/tokens.ts";
import { parseViewerToken } from "../_shared/validation.ts";

const HEADERS = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

export function createContactConfirmHandler(dependencies: {
  lifecycle: LifecycleGateway;
  logger: SafeLogger;
  now: () => number;
}) {
  return async (request: Request): Promise<Response> => {
    const startedAt = dependencies.now();
    const id = requestId(request);
    let status = 500;
    let code: string | undefined;
    try {
      if (request.method !== "POST") throw new ApiError(405, "METHOD_NOT_ALLOWED", "Method not allowed.");
      const match = /\/v1\/contacts\/confirm\/([^/]+)$/.exec(new URL(request.url).pathname.replace(/\/+$/, ""));
      if (!match) throw new ApiError(404, "NOT_FOUND", "This confirmation link is unavailable.");
      const token = parseViewerToken(match[1]);
      if (request.headers.get("X-SignalWord-Action") === "withdraw") {
        const withdrawn = await dependencies.lifecycle.withdrawContact(await sha256Hex(token));
        if (!withdrawn) throw new ApiError(410, "LINK_UNAVAILABLE", "This contact link is unavailable.");
        status = 200;
        return jsonResponse({ withdrawn: true }, status, { ...HEADERS, "X-Request-ID": id });
      }
      if (request.headers.has("X-SignalWord-Action")) {
        throw new ApiError(400, "INVALID_REQUEST", "Invalid contact action.");
      }
      const confirmed = await dependencies.lifecycle.confirmContact(await sha256Hex(token));
      if (!confirmed) throw new ApiError(410, "LINK_UNAVAILABLE", "This confirmation link is unavailable.");
      status = 200;
      return jsonResponse({ confirmed: true }, status, { ...HEADERS, "X-Request-ID": id });
    } catch (caught) {
      const parsed = asApiError(caught);
      const error = parsed.code === "INVALID_REQUEST" || parsed.code === "NOT_FOUND"
        ? new ApiError(410, "LINK_UNAVAILABLE", "This confirmation link is unavailable.")
        : parsed;
      status = error.status;
      code = error.code;
      return errorResponse(error, id, { ...HEADERS, "X-Request-ID": id });
    } finally {
      writeSafely(dependencies.logger, {
        requestId: id, route: "contact-confirm", method: request.method,
        status, durationMs: Math.max(0, dependencies.now() - startedAt),
        ...(code ? { code } : {}),
      });
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required");
  Deno.serve(createContactConfirmHandler({
    lifecycle: createLifecycleGateway({ url, anonKey, serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"), journal: journalFromEnvironment() }),
    logger: structuredLogger,
    now: () => Date.now(),
  }));
}
