import { ApiError, asApiError, errorResponse, jsonResponse, requestId } from "../_shared/http.ts";
import { sha256Hex } from "../_shared/tokens.ts";

const HEADERS = { "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };

export function createDeletionStatusHandler(findReceipt: (hashHex: string) => Promise<string | null>) {
  return async (request: Request): Promise<Response> => {
    const id = requestId(request);
    try {
      if (request.method !== "GET" || !new URL(request.url).pathname.endsWith("/v1/deletions/status")) {
        throw new ApiError(404, "NOT_FOUND", "Route not found.");
      }
      const token = request.headers.get("X-Deletion-Receipt") ?? "";
      if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
        throw new ApiError(400, "INVALID_REQUEST", "A deletion receipt is required.");
      }
      const deletionId = await findReceipt(await sha256Hex(token));
      return jsonResponse({ deleted: deletionId !== null }, 200, HEADERS);
    } catch (caught) {
      return errorResponse(asApiError(caught), id, HEADERS);
    }
  };
}

if (import.meta.main) {
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) throw new Error("Backend service configuration is required");
  Deno.serve(createDeletionStatusHandler(async (hashHex) => {
    let response: Response;
    try {
      response = await fetch(`${url.replace(/\/$/, "")}/rest/v1/rpc/find_deletion_receipt`, {
        method: "POST", signal: AbortSignal.timeout(5000),
        headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_receipt_hash: `\\x${hashHex}` }),
      });
    } catch {
      throw new ApiError(503, "SERVICE_UNAVAILABLE", "Deletion status is temporarily unavailable.", true);
    }
    if (!response.ok) throw new ApiError(503, "SERVICE_UNAVAILABLE", "Deletion status is temporarily unavailable.", true);
    const result = await response.json();
    if (result !== null && (typeof result !== "string" || !/^[0-9a-f-]{36}$/i.test(result))) {
      throw new ApiError(503, "SERVICE_UNAVAILABLE", "Deletion status is temporarily unavailable.", true);
    }
    return result;
  }));
}
