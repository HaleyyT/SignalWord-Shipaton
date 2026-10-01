import { ApiError, asApiError, errorResponse, jsonResponse, requestId } from "../_shared/http.ts";
import { structuredLogger, writeSafely, type SafeLogger } from "../_shared/logging.ts";
import { parsePublicProjection } from "../_shared/public-projection.ts";
import { createBackendGateway, type BackendGateway } from "../_shared/supabase.ts";
import { sha256Hex } from "../_shared/tokens.ts";
import { parseViewerToken } from "../_shared/validation.ts";

export interface PublicEventDependencies {
  backend: BackendGateway;
  logger: SafeLogger;
  now: () => number;
}

const SECURITY_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Security-Policy": "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
  "Referrer-Policy": "no-referrer",
  "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
  "X-Content-Type-Options": "nosniff",
};

const unavailable = () => new ApiError(404, "NOT_FOUND", "This alert is unavailable.");

export function createPublicEventHandler(dependencies: PublicEventDependencies) {
  return async (request: Request): Promise<Response> => {
    const startedAt = dependencies.now();
    const id = requestId(request);
    let status = 500;
    let code: string | undefined;

    try {
      if (!["GET", "POST"].includes(request.method)) {
        throw new ApiError(405, "METHOD_NOT_ALLOWED", "Method not allowed.");
      }
      const path = new URL(request.url).pathname.replace(/\/+$/, "");
      const match = /\/v1\/public\/events\/([^/]+)$/.exec(path);
      if (!match) throw unavailable();

      const token = parseViewerToken(match[1]);
      if (request.method === "POST") {
        if (request.headers.get("X-SignalWord-Action") !== "acknowledge") throw new ApiError(400, "INVALID_REQUEST", "An explicit acknowledgement is required.");
        if (!await dependencies.backend.acknowledge(await sha256Hex(token))) throw unavailable();
        status = 200;
        return jsonResponse({ acknowledged: true }, status, SECURITY_HEADERS);
      }
      const projection = await dependencies.backend.publicEvent(await sha256Hex(token));
      if (projection === null) throw unavailable();

      status = 200;
      return jsonResponse(parsePublicProjection(projection), status, { ...SECURITY_HEADERS, "X-Request-ID": id });
    } catch (caught) {
      const error = asApiError(caught);
      status = error.status;
      code = error.code;
      return errorResponse(error, id, { ...SECURITY_HEADERS, "X-Request-ID": id });
    } finally {
      writeSafely(dependencies.logger, {
        requestId: id,
        route: "public-event",
        method: request.method,
        status,
        durationMs: Math.max(0, dependencies.now() - startedAt),
        ...(code ? { code } : {}),
      });
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !anonKey) throw new Error("SUPABASE_URL and SUPABASE_ANON_KEY are required");
  Deno.serve(createPublicEventHandler({
    backend: createBackendGateway({ url, anonKey }),
    logger: structuredLogger,
    now: () => Date.now(),
  }));
}
