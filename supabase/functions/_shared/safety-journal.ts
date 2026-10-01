import { ApiError } from "./http.ts";

export interface SafetyJournal {
  flush(userId?: string, requireEmpty?: boolean): Promise<void>;
}

/** Replay is idempotent at both stores. A lost response never means deletion is complete. */
export function createSafetyJournal(config: {
  url: string;
  serviceRoleKey: string;
  controlUrl: string;
  writerKey: string;
}): SafetyJournal {
  const unavailable = () =>
    new ApiError(
      503,
      "SERVICE_UNAVAILABLE",
      "Privacy changes are still being saved. Please retry.",
      true,
    );
  async function request(
    url: string,
    body: unknown,
    headers: Record<string, string>,
    deadline?: AbortSignal,
  ): Promise<unknown> {
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { ...headers, "Content-Type": "application/json" },
        body: JSON.stringify(body),
        signal: deadline
          ? AbortSignal.any([deadline, AbortSignal.timeout(3000)])
          : AbortSignal.timeout(3000),
      });
      if (!response.ok) throw unavailable();
      // PostgreSQL void RPCs return 204, not a JSON null body.
      if (response.status === 204) return null;
      return await response.json();
    } catch {
      throw unavailable();
    }
  }
  const rpc = (name: string, body: unknown, deadline?: AbortSignal) =>
    request(`${config.url.replace(/\/$/, "")}/rest/v1/rpc/${name}`, body, {
      apikey: config.serviceRoleKey,
      Authorization: `Bearer ${config.serviceRoleKey}`,
    }, deadline);
  return {
    async flush(userId, requireEmpty = true) {
      const deadline = AbortSignal.timeout(10_000);
      if (
        !/^https:\/\/[^/?#]+$/.test(config.controlUrl) ||
        config.writerKey.length < 32
      ) throw unavailable();
      // Keep work bounded. Larger backlogs continue at the next scheduled opportunity.
      const pending = await rpc("journal_pending", {
        p_user_id: userId ?? null,
        p_limit: 10,
      }, deadline);
      if (!Array.isArray(pending)) throw unavailable();
      for (const entry of pending) {
        const result = await request(`${config.controlUrl}/journal`, entry, {
          Authorization: `Bearer ${config.writerKey}`,
        }, deadline) as { durable?: boolean };
        if (result?.durable !== true) throw unavailable();
        await rpc("journal_mark_durable", { p_id: entry.id }, deadline);
      }
      await rpc(
        "finish_journaled_deletion",
        { p_user_id: userId ?? null },
        deadline,
      );
      if (!requireEmpty) return;
      const remaining = await rpc("journal_pending", {
        p_user_id: userId ?? null,
        p_limit: 1,
      }, deadline);
      if (!Array.isArray(remaining) || remaining.length > 0) {
        throw unavailable();
      }
    },
  };
}

export function journalFromEnvironment(): SafetyJournal {
  return createSafetyJournal({
    url: Deno.env.get("SUPABASE_URL") ?? "",
    serviceRoleKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    controlUrl: Deno.env.get("SAFETY_CONTROL_URL") ?? "",
    writerKey: Deno.env.get("SAFETY_CONTROL_WRITER") ?? "",
  });
}
