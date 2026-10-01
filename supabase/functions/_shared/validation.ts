import { ApiError } from "./http.ts";

export type AlertKind = "test" | "real";
export type TriggerMethod = "vocalShortcut" | "siri" | "actionButton" | "manual";

export interface LocationInput {
  latitude: number;
  longitude: number;
  horizontalAccuracyM: number;
  capturedAt: string;
}

export interface CreateAlertInput {
  kind: AlertKind;
  triggerMethod: TriggerMethod;
  clientTriggeredAt: string;
  device?: { batteryPercent: number; lowPowerMode: boolean };
  location?: LocationInput;
}

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function invalid(message: string): never {
  throw new ApiError(400, "INVALID_REQUEST", message);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isTimestamp(value: unknown): value is string {
  return typeof value === "string" && value.length <= 40 &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    Number.isFinite(Date.parse(value));
}

export function parseIdempotencyKey(value: string | null): string {
  if (!value || !UUID_PATTERN.test(value)) invalid("Idempotency-Key must be a UUID.");
  return value;
}

export function parseCreateAlert(value: unknown, nowMilliseconds = Date.now()): CreateAlertInput {
  if (!isRecord(value)) invalid("Request body must be an object.");
  if (Object.keys(value).some(key => !["kind","triggerMethod","clientTriggeredAt","device","location","idempotencyKey"].includes(key))) invalid("Unsupported alert field.");
  if ("idempotencyKey" in value) invalid("Idempotency-Key must be sent only as a header.");
  if (value.kind !== "test" && value.kind !== "real") invalid("kind must be test or real.");
  if (!["vocalShortcut", "siri", "actionButton", "manual"].includes(String(value.triggerMethod))) {
    invalid("triggerMethod is invalid.");
  }
  if (!isTimestamp(value.clientTriggeredAt)) invalid("clientTriggeredAt must be an RFC 3339 timestamp.");

  let device: CreateAlertInput["device"];
  if (value.device !== undefined) {
    if (!isRecord(value.device) || typeof value.device.batteryPercent !== "number" ||
      !Number.isInteger(value.device.batteryPercent) || value.device.batteryPercent < 0 ||
      value.device.batteryPercent > 100 || typeof value.device.lowPowerMode !== "boolean") {
      invalid("device is invalid.");
    }
    device = { batteryPercent: value.device.batteryPercent, lowPowerMode: value.device.lowPowerMode };
  }

  let location: LocationInput | undefined;
  if (value.location !== undefined) {
    if (!isRecord(value.location) || typeof value.location.latitude !== "number" ||
      !Number.isFinite(value.location.latitude) || value.location.latitude < -90 || value.location.latitude > 90 ||
      typeof value.location.longitude !== "number" || !Number.isFinite(value.location.longitude) ||
      value.location.longitude < -180 || value.location.longitude > 180 ||
      typeof value.location.horizontalAccuracyM !== "number" ||
      !Number.isFinite(value.location.horizontalAccuracyM) || value.location.horizontalAccuracyM < 0 ||
      value.location.horizontalAccuracyM > 100_000 || !isTimestamp(value.location.capturedAt)) {
      invalid("location is invalid.");
    }
    const capturedAtMilliseconds = Date.parse(value.location.capturedAt);
    // Device clocks are not trusted. An implausibly future or old sample is
    // omitted so location can never block the alert itself.
    if (capturedAtMilliseconds >= nowMilliseconds - 86_400_000 &&
      capturedAtMilliseconds <= nowMilliseconds + 300_000) {
      location = {
        latitude: value.location.latitude,
        longitude: value.location.longitude,
        horizontalAccuracyM: value.location.horizontalAccuracyM,
        capturedAt: value.location.capturedAt,
      };
    }
  }

  return {
    kind: value.kind,
    triggerMethod: value.triggerMethod as TriggerMethod,
    clientTriggeredAt: value.clientTriggeredAt,
    ...(device ? { device } : {}),
    ...(location ? { location } : {}),
  };
}

export function parseViewerToken(value: string): string {
  if (!/^[A-Za-z0-9_-]{43}$/.test(value)) {
    throw new ApiError(404, "NOT_FOUND", "This alert is unavailable.");
  }
  return value;
}
