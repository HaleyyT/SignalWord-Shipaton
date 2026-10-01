import { ApiError } from "./http.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 && Number.isFinite(Date.parse(value));
}

function fail(): never {
  throw new ApiError(503, "SERVICE_UNAVAILABLE", "The alert is temporarily unavailable.", true);
}

/** Rebuilds the public allowlist so future database columns cannot leak. */
export function parsePublicProjection(value: unknown): Record<string, unknown> {
  if (!isRecord(value)) fail();
  const { kind, displayName, state, triggeredAt, lastUpdatedAt, location, guidance } = value;
  if ((kind !== "test" && kind !== "real") || typeof displayName !== "string" ||
    displayName.length < 1 || displayName.length > 80 ||
    (state !== "active" && state !== "resolved" && state !== "expired") ||
    !isTimestamp(triggeredAt) || !isTimestamp(lastUpdatedAt) || !isRecord(guidance) ||
    typeof guidance.summary !== "string" || guidance.summary.length < 1 || guidance.summary.length > 500) {
    fail();
  }

  let safeLocation: Record<string, unknown> | undefined;
  if (location !== undefined) {
    if (!isRecord(location) || typeof location.latitude !== "number" ||
      !Number.isFinite(location.latitude) || location.latitude < -90 || location.latitude > 90 ||
      typeof location.longitude !== "number" || !Number.isFinite(location.longitude) ||
      location.longitude < -180 || location.longitude > 180 ||
      typeof location.horizontalAccuracyM !== "number" || !Number.isFinite(location.horizontalAccuracyM) ||
      location.horizontalAccuracyM < 0 || location.horizontalAccuracyM > 100_000 ||
      !isTimestamp(location.capturedAt) ||
      !["live", "recent", "stale", "unavailable"].includes(String(location.freshness))) {
      fail();
    }
    safeLocation = {
      latitude: location.latitude,
      longitude: location.longitude,
      horizontalAccuracyM: location.horizontalAccuracyM,
      capturedAt: location.capturedAt,
      freshness: location.freshness,
    };
  }

  return {
    kind,
    ...(value.cause === "missed_check_in" ? {cause: "missed_check_in"} : {}),
    ...(isTimestamp(value.checkInDeadline) ? {checkInDeadline: value.checkInDeadline} : {}),
    displayName,
    state,
    triggeredAt,
    lastUpdatedAt,
    ...(isTimestamp(value.acknowledgedAt) ? { acknowledgedAt: value.acknowledgedAt } : {}),
    ...(isTimestamp(value.serverNow) ? { serverNow: value.serverNow } : {}),
    ...(isTimestamp(value.clientTriggeredAt) ? { clientTriggeredAt: value.clientTriggeredAt } : {}),
    ...(safeLocation ? { location: safeLocation } : {}),
    guidance: { summary: guidance.summary },
  };
}
