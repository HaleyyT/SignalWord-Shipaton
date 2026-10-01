import { isAbortError, ViewerRequestError } from './api'
import type { EventState, PublicEvent } from './model'

export const ACTIVE_POLL_INTERVAL_MS = 10_000
export const RESOLVED_POLL_INTERVAL_MS = 60_000
export const MAX_BACKOFF_MS = 60_000

/** Bounded exponential backoff for transient viewer failures. */
export function nextPollDelay(
  failureCount: number,
  eventState: EventState = 'active',
  retryAfterMs?: number,
): number | null {
  if (eventState === 'expired') return null

  const healthyInterval = eventState === 'resolved'
    ? RESOLVED_POLL_INTERVAL_MS
    : ACTIVE_POLL_INTERVAL_MS
  const backoff = failureCount <= 0
    ? healthyInterval
    : Math.max(
        healthyInterval,
        Math.min(ACTIVE_POLL_INTERVAL_MS * 2 ** failureCount, MAX_BACKOFF_MS),
      )
  const boundedRetryAfter = retryAfterMs === undefined
    ? 0
    : Math.min(Math.max(retryAfterMs, 0), MAX_BACKOFF_MS)

  return Math.max(backoff, boundedRetryAfter)
}

export type PublicEventLoadState =
  | { status: 'loading' }
  | { status: 'unavailable' }
  | { status: 'error'; event?: PublicEvent }
  | { status: 'loaded'; event: PublicEvent }

interface TimerScheduler {
  setTimer(callback: () => void, delay: number): unknown
  clearTimer(timer: unknown): void
}

export interface PublicEventPollerDependencies {
  fetchEvent(token: string, signal: AbortSignal): Promise<PublicEvent>
  onState(state: PublicEventLoadState): void
  scheduler?: TimerScheduler
}

const browserScheduler: TimerScheduler = {
  setTimer: (callback, delay) => setTimeout(callback, delay),
  clearTimer: (timer) => clearTimeout(timer as ReturnType<typeof setTimeout>),
}

/** Owns one viewer token's request/timer lifecycle and rejects stale completions. */
export class PublicEventPoller {
  private readonly scheduler: TimerScheduler
  private timer: unknown
  private controller: AbortController | undefined
  private requestGeneration = 0
  private failureCount = 0
  private latestEvent: PublicEvent | undefined
  private visible = true
  private stopped = true
  private terminal = false

  constructor(
    private readonly token: string,
    private readonly dependencies: PublicEventPollerDependencies,
  ) {
    this.scheduler = dependencies.scheduler ?? browserScheduler
  }

  start(visible = true): void {
    if (!this.stopped) return
    this.stopped = false
    this.visible = visible
    this.dependencies.onState({ status: 'loading' })
    if (visible) void this.load()
  }

  setVisible(visible: boolean): void {
    if (this.stopped || this.terminal || this.visible === visible) return
    this.visible = visible
    this.clearTimer()

    if (!visible) {
      this.cancelActiveRequest()
      return
    }

    void this.load()
  }

  stop(): void {
    if (this.stopped) return
    this.stopped = true
    this.clearTimer()
    this.cancelActiveRequest()
  }

  private clearTimer(): void {
    if (this.timer === undefined) return
    this.scheduler.clearTimer(this.timer)
    this.timer = undefined
  }

  private cancelActiveRequest(): void {
    this.requestGeneration += 1
    this.controller?.abort()
    this.controller = undefined
  }

  private schedule(delay: number | null): void {
    this.clearTimer()
    if (delay === null || this.stopped || !this.visible) return
    this.timer = this.scheduler.setTimer(() => {
      this.timer = undefined
      void this.load()
    }, delay)
  }

  private async load(): Promise<void> {
    if (this.stopped || !this.visible || this.controller) return

    const controller = new AbortController()
    const generation = ++this.requestGeneration
    this.controller = controller

    try {
      const event = await this.dependencies.fetchEvent(this.token, controller.signal)
      if (!this.isCurrent(generation)) return

      this.latestEvent = event
      this.failureCount = 0
      this.dependencies.onState({ status: 'loaded', event })
      this.terminal = event.state === 'expired'
      this.schedule(nextPollDelay(0, event.state))
    } catch (error) {
      if (!this.isCurrent(generation) || isAbortError(error)) return

      if (error instanceof ViewerRequestError && error.kind === 'unavailable') {
        this.dependencies.onState({ status: 'unavailable' })
        this.terminal = true
        this.schedule(null)
        return
      }

      this.failureCount += 1
      this.dependencies.onState({ status: 'error', event: this.latestEvent })
      this.schedule(nextPollDelay(
        this.failureCount,
        this.latestEvent?.state,
        error instanceof ViewerRequestError ? error.retryAfterMs : undefined,
      ))
    } finally {
      if (generation === this.requestGeneration) this.controller = undefined
    }
  }

  private isCurrent(generation: number): boolean {
    return !this.stopped && this.visible && generation === this.requestGeneration
  }
}
