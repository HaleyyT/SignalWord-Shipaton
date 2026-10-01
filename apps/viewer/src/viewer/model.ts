export type AlertKind = 'test' | 'real'
export type EventState = 'active' | 'resolved' | 'expired'
export type Freshness = 'live' | 'recent' | 'stale' | 'unavailable'

export interface PublicLocation {
  latitude: number
  longitude: number
  horizontalAccuracyM: number
  capturedAt: string
  freshness: Freshness
}

export interface PublicEvent {
  cause?: 'missed_check_in'
  checkInDeadline?: string
  kind: AlertKind
  displayName: string
  state: EventState
  triggeredAt: string
  lastUpdatedAt: string
  acknowledgedAt?: string
  serverNow?: string
  clientTriggeredAt?: string
  location?: PublicLocation
  guidance: { summary: string }
}

export const freshnessCopy: Record<Freshness, string> = {
  live: 'Location updated within the last 30 seconds',
  recent: 'Location updated recently',
  stale: 'Location may no longer reflect the current position',
  unavailable: 'Location is unavailable',
}

export const eventStateCopy: Record<EventState, string> = {
  active: 'Alert active',
  resolved: 'Alert resolved',
  expired: 'Alert expired',
}

export function locationMapURL(location: PublicLocation): string {
  const latitude = location.latitude.toFixed(6)
  const longitude = location.longitude.toFixed(6)
  return `https://www.openstreetmap.org/?mlat=${latitude}&mlon=${longitude}#map=17/${latitude}/${longitude}`
}

/** Never let a cached sample become fresher during an outage or a clock rollback. */
export function agedFreshness(location: PublicLocation, elapsedSeconds: number): Freshness {
  const floor = location.freshness === 'stale' ? 121 : location.freshness === 'recent' ? 31 : 0
  if (location.freshness === 'unavailable') return 'unavailable'
  const age = floor + Math.max(0, elapsedSeconds)
  return age > 120 ? 'stale' : age > 30 ? 'recent' : 'live'
}
