import { HomePage } from './pages/HomePage'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ViewerApp } from './viewer/ViewerApp'
import { PrivacyPage } from './pages/PrivacyPage'
import { SupportPage } from './pages/SupportPage'
import { UnavailablePage } from './pages/UnavailablePage'
import { ContactConfirmationPage } from './pages/ContactConfirmationPage'
import { pageForPath } from './pages/route'
import './styles.css'

const root = document.getElementById('root')

if (!root) {
  throw new Error('Viewer root is missing.')
}

const page = pageForPath(window.location.pathname)
const content = page === 'home'
  ? <HomePage />
  : page === 'event'
  ? <ViewerApp />
  : page === 'confirm'
    ? <ContactConfirmationPage />
  : page === 'privacy'
    ? <PrivacyPage />
    : page === 'support'
      ? <SupportPage />
      : <UnavailablePage />

createRoot(root).render(<StrictMode>{content}</StrictMode>)
