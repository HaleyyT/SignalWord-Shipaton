export interface SafeLogEvent {
  requestId: string;
  route: "user-api" | "public-event" | "contact-confirm";
  method: string;
  operation?: "profile" | "contact" | "check-in" | "contact-network" | "alert" | "account-deletion" | "other";
  status: number;
  durationMs: number;
  code?: string;
  reused?: boolean;
}

export interface SafeLogger {
  write(event: SafeLogEvent): void;
}

export const structuredLogger: SafeLogger = {
  write(event) {
    // The explicit type is the allowlist: tokens, auth, destinations, location,
    // request bodies, and user identifiers cannot be passed to this logger.
    console.info(JSON.stringify({ requestId: event.requestId, route: event.route,
      method: ["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"].includes(event.method) ? event.method : "OTHER", status: event.status, durationMs: event.durationMs,
      ...(event.code === undefined ? {} : { code: event.code }),
      ...(["profile", "contact", "check-in", "contact-network", "alert", "account-deletion", "other"].includes(event.operation ?? "") ? { operation: event.operation } : {}),
      ...(event.reused === undefined ? {} : { reused: event.reused }),
    }));
  },
};

export const silentLogger: SafeLogger = { write() {} };

/** Logging must never replace a successfully committed API response with failure. */
export function writeSafely(logger: SafeLogger, event: SafeLogEvent): void {
  try { logger.write(event); } catch { /* Monitoring outages are observed independently. */ }
}
