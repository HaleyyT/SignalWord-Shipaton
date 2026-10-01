import { afterEach, describe, expect, it, vi } from 'vitest'
import publicEventFixture from '../../../../contracts/v1/public-event.response.json'
import {
  fetchPublicEvent,
  MAX_RETRY_AFTER_MS,
  parsePublicEvent,
  retryAfterMilliseconds,
  viewerTokenFromPath,
} from './api'
import { eventStateCopy, freshnessCopy, locationMapURL } from './model'

const token = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ'
const validPayload = {
  kind: 'test',
  displayName: 'Sample user',
  state: 'active',
  triggeredAt: '2026-09-21T00:00:01Z',
  lastUpdatedAt: '2026-09-21T00:00:12Z',
  guidance: { summary: 'Contact Sample user now.' },
} as const

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('public viewer boundaries', () => {
  it('decodes the shared public-event contract example', () => {
    expect(parsePublicEvent(publicEventFixture)).toEqual(publicEventFixture)
  })

  it('only accepts a 256-bit event token in the exact route shape', () => {
    expect(viewerTokenFromPath('/events/short')).toBeNull()
    expect(viewerTokenFromPath(`/events/${token}`)).toBe(token)
    expect(viewerTokenFromPath(`/events/${token}/extra`)).toBeNull()
    expect(viewerTokenFromPath(`/events/${token}?copy=1`)).toBeNull()
  })

  it('labels stale location honestly and generates a direct map link', () => {
    expect(freshnessCopy.stale).toMatch(/may no longer/i)
    expect(locationMapURL({ latitude: -33.8688, longitude: 151.2093, horizontalAccuracyM: 18, capturedAt: '2026-09-21T00:00:00Z', freshness: 'live' }))
      .toContain('openstreetmap.org')
  })

  it('uses complete, user-facing labels for every alert state', () => {
    expect(eventStateCopy.active).toBe('Alert active')
    expect(eventStateCopy.resolved).toBe('Alert resolved')
    expect(eventStateCopy.expired).toBe('Alert expired')
  })

  it('rebuilds the public projection and discards unapproved response fields', () => {
    const event = parsePublicEvent({
      ...validPayload,
      guidance: { ...validPayload.guidance, internalInstruction: 'discard me' },
      internalEventID: 'must-not-reach-the-viewer',
    })

    expect(event).toEqual(validPayload)
    expect(event).not.toHaveProperty('internalEventID')
  })

  it.each([
    { ...validPayload, kind: 'unknown' },
    { ...validPayload, displayName: '' },
    { ...validPayload, state: 'pending' },
    { ...validPayload, triggeredAt: 'not-a-date' },
    { ...validPayload, guidance: { summary: '' } },
    { ...validPayload, location: { latitude: 91, longitude: 0, horizontalAccuracyM: 1, capturedAt: validPayload.triggeredAt, freshness: 'live' } },
  ])('rejects malformed public-event payloads', (payload) => {
    expect(() => parsePublicEvent(payload)).toThrow('INVALID_PUBLIC_EVENT')
  })
})

describe('public event HTTP behavior', () => {
  it('requests only the token-scoped endpoint without cache persistence', async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json(validPayload))
    vi.stubGlobal('fetch', fetchMock)
    const controller = new AbortController()

    await expect(fetchPublicEvent(token, controller.signal)).resolves.toEqual(validPayload)
    expect(fetchMock).toHaveBeenCalledWith(`/v1/public/events/${token}`, {
      cache: 'no-store',
      signal: controller.signal,
      headers: { Accept: 'application/json' },
    })
  })

  it.each([400, 401, 403, 404, 410, 422])('treats HTTP %i as generically unavailable', async (status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status })))
    await expect(fetchPublicEvent(token)).rejects.toMatchObject({
      kind: 'unavailable',
      message: 'EVENT_UNAVAILABLE',
    })
  })

  it.each([408, 429, 500, 502, 503, 504])('treats HTTP %i as retryable', async (status) => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, { status })))
    await expect(fetchPublicEvent(token)).rejects.toMatchObject({
      kind: 'retryable',
      message: 'EVENT_RETRYABLE',
    })
  })

  it('honors Retry-After without allowing an excessive wait', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue(new Response(null, {
      status: 429,
      headers: { 'Retry-After': '3600' },
    })))

    await expect(fetchPublicEvent(token)).rejects.toMatchObject({
      kind: 'retryable',
      retryAfterMs: MAX_RETRY_AFTER_MS,
    })
  })

  it('treats network and malformed-success failures as retryable', async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError('network unavailable'))
      .mockResolvedValueOnce(Response.json({ unexpected: true }))
    vi.stubGlobal('fetch', fetchMock)

    await expect(fetchPublicEvent(token)).rejects.toMatchObject({ kind: 'retryable' })
    await expect(fetchPublicEvent(token)).rejects.toMatchObject({ kind: 'retryable' })
  })

  it('propagates cancellation without converting it to a retryable failure', async () => {
    const abortError = new DOMException('cancelled', 'AbortError')
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(abortError))
    await expect(fetchPublicEvent(token)).rejects.toBe(abortError)
  })
})

describe('Retry-After parsing', () => {
  it('supports delta seconds and HTTP dates with deterministic bounds', () => {
    const now = Date.parse('2026-09-24T00:00:00Z')
    expect(retryAfterMilliseconds('15', now)).toBe(15_000)
    expect(retryAfterMilliseconds('Wed, 24 Sep 2026 00:00:20 GMT', now)).toBe(20_000)
    expect(retryAfterMilliseconds('3600', now)).toBe(MAX_RETRY_AFTER_MS)
    expect(retryAfterMilliseconds('-4', now)).toBe(0)
    expect(retryAfterMilliseconds('invalid', now)).toBeUndefined()
  })
})

it('preserves missed-check-in cause and deadline without private timer state', () => {
  const result = parsePublicEvent({...publicEventFixture, cause: 'missed_check_in', checkInDeadline: '2026-09-28T00:15:00Z', recipient_payloads: 'private'})
  expect(result.cause).toBe('missed_check_in')
  expect(result.checkInDeadline).toBe('2026-09-28T00:15:00Z')
  expect(result).not.toHaveProperty('recipient_payloads')
})
