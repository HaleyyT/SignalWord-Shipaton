import { useEffect, useState } from 'react'
import { fetchPublicEvent } from './api'
import { PublicEventPoller, type PublicEventLoadState } from './polling'

export type { PublicEventLoadState } from './polling'

export function usePublicEvent(token: string | null): PublicEventLoadState {
  const [state, setState] = useState<PublicEventLoadState>({ status: 'loading' })

  useEffect(() => {
    if (!token) {
      setState({ status: 'unavailable' })
      return
    }

    const poller = new PublicEventPoller(token, {
      fetchEvent: fetchPublicEvent,
      onState: setState,
    })

    const onVisibilityChange = () => {
      poller.setVisible(document.visibilityState === 'visible')
    }

    document.addEventListener('visibilitychange', onVisibilityChange)
    poller.start(document.visibilityState === 'visible')

    return () => {
      poller.stop()
      document.removeEventListener('visibilitychange', onVisibilityChange)
    }
  }, [token])

  return state
}
