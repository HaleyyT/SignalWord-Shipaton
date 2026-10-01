import { describe, expect, it } from 'vitest'
import { pageForPath } from './route'

describe('public information routes', () => {
  it('keeps support and privacy routes separate from event tokens', () => {
    expect(pageForPath('/')).toBe('home')
    expect(pageForPath('/privacy')).toBe('privacy')
    expect(pageForPath('/support')).toBe('support')
    expect(pageForPath('/events/abcdefghijklmnopqrstuvwxyzABCDEF12')).toBe('event')
    expect(pageForPath('/confirm/abcdefghijklmnopqrstuvwxyzABCDEF12')).toBe('confirm')
    expect(pageForPath('/unknown')).toBe('unavailable')
  })
})
