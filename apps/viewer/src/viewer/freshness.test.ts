import { describe, expect, it } from 'vitest'
import { agedFreshness, type PublicLocation } from './model'
const location: PublicLocation = { latitude: 0, longitude: 0, horizontalAccuracyM: 20, capturedAt: '2026-09-26T00:00:00Z', freshness: 'live' }
describe('cached location age', () => {
  it('ages without a successful refresh', () => {
    expect(agedFreshness(location, 31)).toBe('recent')
    expect(agedFreshness(location, 121)).toBe('stale')
  })
  it('never promotes a stale sample or a clock rollback', () => {
    expect(agedFreshness({ ...location, freshness: 'stale' }, -60)).toBe('stale')
    expect(agedFreshness({ ...location, freshness: 'recent' }, -60)).toBe('recent')
  })
})
