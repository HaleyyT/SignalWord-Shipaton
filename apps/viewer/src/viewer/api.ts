import type { PublicEvent } from './model'

const tokenPattern = /^[A-Za-z0-9_-]{43,128}$/
export const MAX_RETRY_AFTER_MS = 60_000

export type ViewerRequestErrorKind = 'unavailable' | 'retryable'

/**
 * A deliberately small error surface for the public viewer. Callers can decide
 * whether to retry without exposing why a token was rejected.
 */
export class ViewerRequestError extends Error {
  constructor(
    readonly kind: ViewerRequestErrorKind,
    readonly retryAfterMs?: number,
  ) {
    super(kind === 'unavailable' ? 'EVENT_UNAVAILABLE' : 'EVENT_RETRYABLE')
    this.name = 'ViewerRequestError'
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function isTimestamp(value: unknown): value is string {
  return typeof value === 'string' && Number.isFinite(Date.parse(value))
}

function isText(value: unknown, maximumLength: number): value is string {
  return typeof value === 'string' && value.length > 0 && value.length <= maximumLength
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

/**
 * Validates and rebuilds the only data shape a contact viewer is permitted to render.
 * Rebuilding, rather than casting JSON, prevents accidental future API fields from
 * becoming available to the public UI.
 */
export function parsePublicEvent(value: unknown): PublicEvent {
  if (!isRecord(value)) throw new Error('INVALID_PUBLIC_EVENT')

  const { kind, displayName, state, triggeredAt, lastUpdatedAt, location, guidance } = value
  if ((kind !== 'test' && kind !== 'real') ||
    !isText(displayName, 80) ||
    (state !== 'active' && state !== 'resolved' && state !== 'expired') ||
    !isTimestamp(triggeredAt) ||
    !isTimestamp(lastUpdatedAt) ||
    !isRecord(guidance) ||
    !isText(guidance.summary, 500)) {
    throw new Error('INVALID_PUBLIC_EVENT')
  }

  let safeLocation: PublicEvent['location']
  if (location !== undefined) {
    if (!isRecord(location) ||
      !isFiniteNumber(location.latitude) || location.latitude < -90 || location.latitude > 90 ||
      !isFiniteNumber(location.longitude) || location.longitude < -180 || location.longitude > 180 ||
      !isFiniteNumber(location.horizontalAccuracyM) || location.horizontalAccuracyM < 0 || location.horizontalAccuracyM > 100_000 ||
      !isTimestamp(location.capturedAt) ||
      (location.freshness !== 'live' && location.freshness !== 'recent' && location.freshness !== 'stale' && location.freshness !== 'unavailable')) {
      throw new Error('INVALID_PUBLIC_EVENT')
    }
    safeLocation = {
      latitude: location.latitude,
      longitude: location.longitude,
      horizontalAccuracyM: location.horizontalAccuracyM,
      capturedAt: location.capturedAt,
      freshness: location.freshness,
    }
  }

  return {
    kind,
    ...(value.cause === 'missed_check_in' ? {cause: 'missed_check_in' as const} : {}),
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
  }
}

export function viewerTokenFromPath(pathname: string): string | null {
  const match = pathname.match(/^\/events\/([^/]+)$/)
  const token = match?.[1]
  return token && tokenPattern.test(token) ? token : null
}

export function retryAfterMilliseconds(
  value: string | null,
  nowMilliseconds = Date.now(),
): number | undefined {
  if (!value) return undefined

  const seconds = Number(value)
  const unboundedMilliseconds = Number.isFinite(seconds)
    ? seconds * 1_000
    : Date.parse(value) - nowMilliseconds

  if (!Number.isFinite(unboundedMilliseconds)) return undefined
  return Math.min(Math.max(Math.ceil(unboundedMilliseconds), 0), MAX_RETRY_AFTER_MS)
}

export function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === 'AbortError'
}

export async function fetchPublicEvent(token: string, signal?: AbortSignal): Promise<PublicEvent> {
  let response: Response
  try {
    response = await fetch(`/v1/public/events/${encodeURIComponent(token)}`, {
      cache: 'no-store',
      signal,
      headers: { Accept: 'application/json' },
    })
  } catch (error) {
    if (isAbortError(error)) throw error
    throw new ViewerRequestError('retryable')
  }

  if (!response.ok) {
    if (response.status === 408 || response.status === 429 || response.status >= 500) {
      throw new ViewerRequestError('retryable', retryAfterMilliseconds(response.headers.get('Retry-After')))
    }

    // Invalid, expired, revoked, unknown, and unauthorized tokens all look identical.
    throw new ViewerRequestError('unavailable')
  }

  try {
    return parsePublicEvent(await response.json())
  } catch {
    // A malformed successful response is a server fault, not proof that a
    // previously displayed alert has become unavailable.
    throw new ViewerRequestError('retryable')
  }
}

export async function acknowledgeEvent(token: string): Promise<void> {
  const response = await fetch(`/v1/public/events/${encodeURIComponent(token)}`, {
    method: 'POST', cache: 'no-store', signal: AbortSignal.timeout(8000),
    headers: { 'X-SignalWord-Action': 'acknowledge', Accept: 'application/json' },
  })
  if (!response.ok || (await response.json()).acknowledged !== true) throw new Error('ACKNOWLEDGEMENT_FAILED')
}
