import { useEffect, useState } from 'react'
import { acknowledgeEvent, viewerTokenFromPath } from './api'
import { agedFreshness, eventStateCopy, freshnessCopy, locationMapURL, type PublicEvent } from './model'
import { usePublicEvent } from './usePublicEvent'

function formatTime(timestamp: string): string {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(timestamp))
}

export function ViewerApp() {
  const token = viewerTokenFromPath(window.location.pathname)
  const state = usePublicEvent(token)
  const [ack, setAck] = useState<'idle' | 'sending' | 'done' | 'failed'>('idle')
  const [elapsed, setElapsed] = useState(0)
  const receivedEvent = 'event' in state ? state.event : undefined
  useEffect(() => {
    const start = performance.now()
    setElapsed(0)
    const timer = setInterval(() => setElapsed((performance.now() - start) / 1000), 1000)
    return () => clearInterval(timer)
  }, [receivedEvent])
  async function acknowledge() {
    if (!token || ack === 'sending') return
    setAck('sending')
    try { await acknowledgeEvent(token); setAck('done') } catch { setAck('failed') }
  }

  if (state.status === 'loading') {
    return (
      <main className="viewer-shell" aria-busy="true">
        <section className="card loading-card" aria-live="polite">
          <p className="eyebrow">SignalWord</p>
          <div className="skeleton skeleton-heading" />
          <div className="skeleton skeleton-copy" />
          <span className="visually-hidden">Loading alert</span>
        </section>
      </main>
    )
  }

  if (state.status === 'unavailable') {
    return (
      <main className="viewer-shell">
        <section className="card viewer-status-card">
          <p className="eyebrow">SignalWord</p>
          <h1>This alert link is unavailable</h1>
          <p>It may have expired, been resolved and removed, or no longer be valid.</p>
        </section>
      </main>
    )
  }

  if (state.status === 'error' && !state.event) {
    return (
      <main className="viewer-shell">
        <section className="card viewer-status-card">
          <p className="eyebrow">SignalWord</p>
          <h1>Unable to refresh this alert</h1>
          <p>Check your connection and try again shortly.</p>
        </section>
      </main>
    )
  }

  if (!('event' in state) || !state.event) {
    throw new Error('Viewer reached an invalid load state.')
  }

  const event: PublicEvent = state.event
  const location = event.location
  const freshness = location ? agedFreshness(location, elapsed + (event.serverNow ? Math.max(0, (Date.parse(event.serverNow) - Date.parse(location.capturedAt)) / 1000) : 0)) : 'unavailable'

  return (
    <main className="viewer-shell">
      <section className="card" aria-labelledby="alert-title">
        {state.status === 'error' && <p className="refresh-warning" role="status">The information shown may not be current. Retrying…</p>}
        <p className="eyebrow">{event.kind === 'test' ? 'TEST · NO EMERGENCY' : 'REAL ALERT'}</p>
        <h1 id="alert-title">{event.displayName} {event.state === 'resolved' ? 'resolved the alert' : event.cause === 'missed_check_in' ? 'missed a check-in' : 'sent an alert'}</h1>
        {event.cause === 'missed_check_in' && <p>A scheduled check-in was not completed within its grace period. This does not confirm danger. Contact the person directly.{event.checkInDeadline && ` Check-in was due ${formatTime(event.checkInDeadline)}.`}</p>}
        <p className="timestamp">Sent {formatTime(event.triggeredAt)}</p>
        <p className={`state state-${event.state}`} role="status" aria-live="polite" aria-atomic="true">
          {eventStateCopy[event.state]}
        </p>
      </section>

      <section className="card" aria-labelledby="location-title">
        <h2 id="location-title">Latest available location</h2>
        {location ? (
          <>
            <p className={`freshness freshness-${freshness}`}>{freshnessCopy[freshness]}</p>
            <p>{location.latitude.toFixed(5)}, {location.longitude.toFixed(5)}. Accuracy within {Math.round(location.horizontalAccuracyM)} m.</p>
            <p className="timestamp">Captured {formatTime(location.capturedAt)}</p>
            <a className="action-link" href={locationMapURL(location)} rel="noreferrer" target="_blank" aria-label="Open the latest available location in a map, in a new tab">Open in a map</a>
          </>
        ) : (
          <p>Location is unavailable. The alert was accepted by SignalWord.</p>
        )}
      </section>

      <section className="card guidance" aria-labelledby="guidance-title">
        <h2 id="guidance-title">What to do</h2>
        <p>{event.guidance.summary}</p>
        {event.acknowledgedAt || ack === 'done'
          ? <p role="status">Acknowledged through this recipient link. This does not confirm help is coming.</p>
          : event.state !== 'expired' && <>
            <button className="primary-button" disabled={ack === 'sending'} onClick={() => void acknowledge()}>
              {ack === 'sending' ? 'Acknowledging…' : 'Acknowledge this alert'}
            </button>
            <p>Let the sender know this link has been acknowledged. Contact them directly to arrange help.</p>
            {ack === 'failed' && <p role="alert">Acknowledgement was not confirmed. Check your connection and try again.</p>}
          </>}
        <p className="timestamp">Last server update {formatTime(event.lastUpdatedAt)}</p>
      </section>
    </main>
  )
}
