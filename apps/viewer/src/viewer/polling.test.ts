import { describe, expect, it, vi } from 'vitest'
import { ViewerRequestError } from './api'
import type { PublicEvent } from './model'
import {
  ACTIVE_POLL_INTERVAL_MS,
  MAX_BACKOFF_MS,
  nextPollDelay,
  PublicEventPoller,
  RESOLVED_POLL_INTERVAL_MS,
  type PublicEventLoadState,
} from './polling'

const activeEvent: PublicEvent = {
  kind: 'real',
  displayName: 'Sample user',
  state: 'active',
  triggeredAt: '2026-09-24T00:00:00Z',
  lastUpdatedAt: '2026-09-24T00:00:01Z',
  guidance: { summary: 'Contact Sample user now.' },
}

function deferred<T>() {
  let resolve!: (value: T) => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise
    reject = rejectPromise
  })
  return { promise, resolve, reject }
}

async function settle(): Promise<void> {
  await Promise.resolve()
  await Promise.resolve()
}

class FakeScheduler {
  readonly delays: number[] = []
  private tasks = new Map<number, () => void>()
  private nextIdentifier = 1

  setTimer = (callback: () => void, delay: number): number => {
    const identifier = this.nextIdentifier++
    this.tasks.set(identifier, callback)
    this.delays.push(delay)
    return identifier
  }

  clearTimer = (timer: unknown): void => {
    this.tasks.delete(timer as number)
  }

  runNext(): void {
    const entry = this.tasks.entries().next().value as [number, () => void] | undefined
    if (!entry) throw new Error('No scheduled poll')
    this.tasks.delete(entry[0])
    entry[1]()
  }

  get pendingCount(): number {
    return this.tasks.size
  }
}

function makePoller(fetchEvent: (token: string, signal: AbortSignal) => Promise<PublicEvent>) {
  const scheduler = new FakeScheduler()
  const states: PublicEventLoadState[] = []
  const poller = new PublicEventPoller('private-token', {
    fetchEvent,
    onState: (state) => states.push(state),
    scheduler,
  })
  return { poller, scheduler, states }
}

describe('viewer poll timing', () => {
  it('uses state-aware polling and bounded transient backoff', () => {
    expect(nextPollDelay(0, 'active')).toBe(ACTIVE_POLL_INTERVAL_MS)
    expect(nextPollDelay(0, 'resolved')).toBe(RESOLVED_POLL_INTERVAL_MS)
    expect(nextPollDelay(0, 'expired')).toBeNull()
    expect(nextPollDelay(1, 'active')).toBe(20_000)
    expect(nextPollDelay(10, 'active')).toBe(MAX_BACKOFF_MS)
    expect(nextPollDelay(1, 'resolved')).toBe(RESOLVED_POLL_INTERVAL_MS)
    expect(nextPollDelay(1, 'active', 45_000)).toBe(45_000)
    expect(nextPollDelay(1, 'active', 600_000)).toBe(MAX_BACKOFF_MS)
  })
})

describe('PublicEventPoller lifecycle', () => {
  it('does not request a hidden document until it becomes visible', () => {
    const fetchEvent = vi.fn().mockResolvedValue(activeEvent)
    const { poller } = makePoller(fetchEvent)
    poller.start(false)
    expect(fetchEvent).not.toHaveBeenCalled()
    poller.setVisible(true)
    expect(fetchEvent).toHaveBeenCalledTimes(1)
  })

  it('does not overlap polls and schedules only after completion', async () => {
    const first = deferred<PublicEvent>()
    const fetchEvent = vi.fn().mockReturnValueOnce(first.promise).mockResolvedValue(activeEvent)
    const { poller, scheduler, states } = makePoller(fetchEvent)

    poller.start()
    expect(fetchEvent).toHaveBeenCalledTimes(1)
    expect(scheduler.pendingCount).toBe(0)
    poller.start()
    expect(fetchEvent).toHaveBeenCalledTimes(1)

    first.resolve(activeEvent)
    await settle()
    expect(states.at(-1)).toEqual({ status: 'loaded', event: activeEvent })
    expect(scheduler.pendingCount).toBe(1)

    scheduler.runNext()
    await settle()
    expect(fetchEvent).toHaveBeenCalledTimes(2)
    expect(scheduler.pendingCount).toBe(1)
  })

  it('aborts hidden requests and ignores stale responses after visibility resumes', async () => {
    const stale = deferred<PublicEvent>()
    const fresh = deferred<PublicEvent>()
    const signals: AbortSignal[] = []
    const fetchEvent = vi.fn((_token: string, signal: AbortSignal) => {
      signals.push(signal)
      return signals.length === 1 ? stale.promise : fresh.promise
    })
    const { poller, states } = makePoller(fetchEvent)

    poller.start()
    poller.setVisible(false)
    expect(signals[0].aborted).toBe(true)
    poller.setVisible(true)
    expect(fetchEvent).toHaveBeenCalledTimes(2)

    stale.resolve({ ...activeEvent, displayName: 'Stale response' })
    await settle()
    expect(states).not.toContainEqual(expect.objectContaining({ event: expect.objectContaining({ displayName: 'Stale response' }) }))

    fresh.resolve(activeEvent)
    await settle()
    expect(states.at(-1)).toEqual({ status: 'loaded', event: activeEvent })
  })

  it('aborts the active request and clears timers on cleanup', async () => {
    const request = deferred<PublicEvent>()
    let signal: AbortSignal | undefined
    const { poller, scheduler, states } = makePoller((_token, requestSignal) => {
      signal = requestSignal
      return request.promise
    })

    poller.start()
    poller.stop()
    expect(signal?.aborted).toBe(true)
    expect(scheduler.pendingCount).toBe(0)

    request.resolve(activeEvent)
    await settle()
    expect(states).toEqual([{ status: 'loading' }])
  })

  it('preserves the latest safe event during transient errors and recovers', async () => {
    const fetchEvent = vi.fn()
      .mockResolvedValueOnce(activeEvent)
      .mockRejectedValueOnce(new ViewerRequestError('retryable', 45_000))
      .mockResolvedValueOnce({ ...activeEvent, lastUpdatedAt: '2026-09-24T00:01:00Z' })
    const { poller, scheduler, states } = makePoller(fetchEvent)

    poller.start()
    await settle()
    scheduler.runNext()
    await settle()

    expect(states.at(-1)).toEqual({ status: 'error', event: activeEvent })
    expect(scheduler.delays.at(-1)).toBe(45_000)

    scheduler.runNext()
    await settle()
    expect(states.at(-1)).toEqual({
      status: 'loaded',
      event: { ...activeEvent, lastUpdatedAt: '2026-09-24T00:01:00Z' },
    })
  })

  it('stops permanently for unavailable and expired events', async () => {
    const unavailableFetch = vi.fn().mockRejectedValue(new ViewerRequestError('unavailable'))
    const unavailable = makePoller(unavailableFetch)
    unavailable.poller.start()
    await settle()
    expect(unavailable.states.at(-1)).toEqual({ status: 'unavailable' })
    expect(unavailable.scheduler.pendingCount).toBe(0)
    unavailable.poller.setVisible(false)
    unavailable.poller.setVisible(true)
    expect(unavailableFetch).toHaveBeenCalledTimes(1)

    const expiredEvent: PublicEvent = { ...activeEvent, state: 'expired' }
    const expiredFetch = vi.fn().mockResolvedValue(expiredEvent)
    const expired = makePoller(expiredFetch)
    expired.poller.start()
    await settle()
    expect(expired.states.at(-1)).toEqual({ status: 'loaded', event: expiredEvent })
    expect(expired.scheduler.pendingCount).toBe(0)
    expired.poller.setVisible(false)
    expired.poller.setVisible(true)
    expect(expiredFetch).toHaveBeenCalledTimes(1)
  })

  it('polls resolved events less frequently', async () => {
    const resolvedEvent: PublicEvent = { ...activeEvent, state: 'resolved' }
    const { poller, scheduler } = makePoller(vi.fn().mockResolvedValue(resolvedEvent))
    poller.start()
    await settle()
    expect(scheduler.delays).toEqual([RESOLVED_POLL_INTERVAL_MS])
  })
})
