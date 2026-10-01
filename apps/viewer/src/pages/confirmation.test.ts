import { afterEach, describe, expect, it, vi } from 'vitest'
import { confirmationTokenFromPath, confirmTrustedContact, withdrawTrustedContact } from './confirmation'

const token = 'a'.repeat(43)

afterEach(() => vi.unstubAllGlobals())

describe('trusted-contact confirmation', () => {
  it('accepts only one opaque path token', () => {
    expect(confirmationTokenFromPath(`/confirm/${token}`)).toBe(token)
    expect(confirmationTokenFromPath('/confirm/short')).toBeNull()
    expect(confirmationTokenFromPath(`/confirm/${token}/extra`)).toBeNull()
  })

  it('uses an explicit same-origin POST and validates success', async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json({ confirmed: true }))
    vi.stubGlobal('fetch', fetchMock)
    await expect(confirmTrustedContact(token)).resolves.toBe('confirmed')
    expect(fetchMock).toHaveBeenCalledWith(`/api/v1/contacts/confirm/${token}`, expect.objectContaining({
      method: 'POST', cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer',
    }))
  })

  it('distinguishes consumed links from temporary failures', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(null, { status: 410 })))
    await expect(confirmTrustedContact(token)).resolves.toBe('unavailable')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValueOnce(new Response(null, { status: 503 })))
    await expect(confirmTrustedContact(token)).resolves.toBe('temporary')
  })

  it('withdraws only by explicit POST and handles a repeated request', async () => {
    const fetchMock = vi.fn().mockResolvedValue(Response.json({ withdrawn: true }))
    vi.stubGlobal('fetch', fetchMock)
    await expect(withdrawTrustedContact(token)).resolves.toBe('withdrawn')
    expect(fetchMock).toHaveBeenCalledWith(`/api/v1/contacts/confirm/${token}`, expect.objectContaining({
      method: 'POST', headers: { Accept: 'application/json', 'X-SignalWord-Action': 'withdraw' },
    }))
  })
})
