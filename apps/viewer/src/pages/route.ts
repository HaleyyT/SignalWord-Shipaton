export type PublicPage = 'home' | 'event' | 'confirm' | 'privacy' | 'support' | 'unavailable'

export function pageForPath(pathname: string): PublicPage {
  if (pathname === '/') return 'home'
  if (pathname === '/privacy') return 'privacy'
  if (pathname === '/support') return 'support'
  if (pathname.startsWith('/confirm/')) return 'confirm'
  if (pathname.startsWith('/events/')) return 'event'
  return 'unavailable'
}
