import { useEffect } from 'react'
import './home.css'

/** Public information only: visiting home never reads or mutates an alert. */
export function HomePage() {
  useEffect(() => {
    // Hash targets mount after the browser initially parses the HTML shell.
    // Restore deep links and move keyboard/screen-reader focus with navigation.
    const navigateToSection = () => {
      const id = window.location.hash.slice(1)
      if (!['main', 'how-it-works', 'why-signalword', 'for-trusted-contacts'].includes(id)) return
      const target = document.getElementById(id)
      target?.focus({ preventScroll: true })
      target?.scrollIntoView({ block: 'start', behavior: 'instant' })
    }
    navigateToSection()
    window.addEventListener('hashchange', navigateToSection)
    return () => window.removeEventListener('hashchange', navigateToSection)
  }, [])
  return (
    <div className="home-page">
      <a className="home-skip" href="#main">Skip to content</a>
      <header className="home-header home-wrap">
        <a className="wordmark" href="/" aria-label="SignalWord home">
          <img src="/favicon.svg?v=3" width="30" height="30" alt="" />
          <span>SignalWord</span>
        </a>
        <nav aria-label="Main navigation">
          <a href="#how-it-works">How it works</a>
          <a href="#why-signalword">Why SignalWord</a>
          <a href="/support">Support</a>
        </nav>
      </header>
      <main id="main" tabIndex={-1}>
        <section className="home-hero home-wrap" aria-labelledby="home-title">
          <div className="home-hero-copy">
            <p className="eyebrow home-eyebrow"><span className="home-eyebrow-mark" aria-hidden="true" />Voice-triggered iPhone safety</p>
            <h1 id="home-title">Private phrase.<br /><span>Trusted response.</span></h1>
            <p className="home-lede">Alert someone you trust with a private iPhone phrase, a Shortcut or a tap.</p>
            <div className="home-hero-actions">
              <a className="home-button" href="#how-it-works">See how SignalWord works <span aria-hidden="true">→</span></a>
              <a className="home-secondary-link" href="#for-trusted-contacts">For trusted contacts</a>
            </div>
          </div>
          <figure className="home-photo" aria-labelledby="preview-caption">
            <img src="/images/trusted-connection.webp" width="1024" height="1280" fetchPriority="high" alt="Two friends walking together beside the sea at dusk." />
            <div className="home-photo-shade" aria-hidden="true" />
            <div className="home-preview">
              <div className="home-preview-head">
                <span className="home-preview-kicker">Example alert flow</span>
              </div>
              <div className="home-preview-detected">
                <div className="home-waveform" aria-hidden="true">
                  {[12, 20, 30, 17, 26, 34, 21, 13, 23, 16, 10].map((height, index) => (
                    <span key={index} style={{ height: `${height}px`, animationDelay: `${index * -0.13}s` }} />
                  ))}
                </div>
                <div>
                  <strong>Phrase detected</strong>
                  <span>Private phrase recognised</span>
                </div>
              </div>
              <ol className="home-preview-states" aria-label="Example alert states">
                <li><span className="home-state-mark" aria-hidden="true">✓</span><span>Alert sent</span></li>
                <li><span className="home-state-mark" aria-hidden="true">✓</span><span>Trusted contact notified</span></li>
                <li className="home-state-current"><span className="home-state-mark" aria-hidden="true" /><span>Awaiting acknowledgement</span></li>
              </ol>
              <div className="home-preview-foot">
                <span className="home-location-chip"><span aria-hidden="true" /> Optional location snapshot</span>
              </div>
            </div>
            <figcaption id="preview-caption">Example states for illustration. Delivery and acknowledgement depend on connectivity and recipient action.</figcaption>
          </figure>
        </section>

        <aside className="home-status home-wrap" aria-label="Pricing">
          <span className="home-status-icon" aria-hidden="true">Free</span>
          <div><strong>Safety features stay free</strong><p>Alerts, trusted contacts and check-ins are free. One optional Supporter purchase unlocks both Ocean and Lavender colour themes.</p></div>
        </aside>

        <section className="home-section home-wrap" id="how-it-works" tabIndex={-1} aria-labelledby="how-title">
          <div className="home-section-intro">
            <h2 id="how-title">A small phrase.<br /><span>A considered response.</span></h2>
            <p>Set up the connection before you need it, then practise the flow together.</p>
          </div>
          <ol className="home-steps">
            <li>
              <span className="home-step-number" aria-hidden="true">01</span>
              <h3>Choose a private phrase</h3>
              <p>Train a phrase in iPhone Vocal Shortcuts. iOS manages phrase recognition; SignalWord does not need the audio.</p>
            </li>
            <li>
              <span className="home-step-number" aria-hidden="true">02</span>
              <h3>Trigger with your voice</h3>
              <p>Say your phrase or use the SignalWord action with Siri or the Shortcuts app when reaching for the screen is difficult.</p>
            </li>
            <li>
              <span className="home-step-number" aria-hidden="true">03</span>
              <h3>Alert someone you trust</h3>
              <p>SignalWord creates a clearly labelled TEST or REAL alert for the person who confirmed your invitation.</p>
            </li>
            <li>
              <span className="home-step-number" aria-hidden="true">04</span>
              <h3>They acknowledge and respond</h3>
              <p>Your person opens a private link, acknowledges what they’ve seen, and decides how to respond or whether to contact further help.</p>
            </li>
          </ol>
        </section>

        <section className="home-difference home-wrap" id="why-signalword" tabIndex={-1} aria-labelledby="difference-title">
          <div className="home-difference-intro">
            <h2 id="difference-title">Designed for the moment you can’t use your phone as usual.</h2>
            <p>A familiar, voice-led route to a person you chose, with clear signals about what happened next.</p>
          </div>
          <div className="home-difference-list">
            <article>
              <span className="home-difference-index">01</span>
              <div><h3>Discreet, hands-free activation</h3><p>A phrase or Shortcut can start the flow when typing, unlocking, or calling may not feel safe.</p></div>
            </article>
            <article>
              <span className="home-difference-index">02</span>
              <div><h3>Less to do under stress</h3><p>Choose and practise your route in advance, so the first step is familiar when it matters.</p></div>
            </article>
            <article>
              <span className="home-difference-index">03</span>
              <div><h3>A trusted-contact workflow</h3><p>Your person confirms consent before SignalWord can send them TEST or REAL alerts.</p></div>
            </article>
            <article>
              <span className="home-difference-index">04</span>
              <div><h3>Clear confirmation states</h3><p>Alert acceptance, email delivery, acknowledgement, and resolution stay distinct. An acknowledgement does not guarantee help is coming.</p></div>
            </article>
          </div>
        </section>

        <section className="home-recipient home-wrap" id="for-trusted-contacts" tabIndex={-1} aria-labelledby="recipient-title">
          <div><p className="eyebrow">For trusted contacts</p><h2 id="recipient-title">Received a SignalWord email?</h2></div>
          <div><p>Open the private link in that email to confirm an invitation or view an alert. You don’t need a SignalWord account.</p>
            <p>Keep the link private. If you receive an unexpected message, contact the sender directly before taking action.</p>
            <a className="action-link" href="/support">Support <span aria-hidden="true"> ↗</span></a>
          </div>
        </section>

        <section className="home-section home-wrap home-faq" aria-labelledby="questions-title">
          <h2 id="questions-title">A few things to know.</h2>
          <details><summary>How do I trigger an alert?</summary><p>Send an alert in the iPhone app, or configure separate TEST and REAL Vocal Shortcuts in iOS. Confirm your trusted contact and practise a TEST alert on your own device before use. Shortcut availability depends on your device settings and connection.</p></details>
          <details><summary>Does SignalWord contact emergency services?</summary><p>No. It notifies your confirmed trusted contact. It does not dispatch police, ambulance or other emergency services. If someone may be in immediate danger, contact local emergency services directly.</p></details>
          <details><summary>Is email delivery guaranteed?</summary><p>No. A network connection and working delivery services are required. Provider acceptance, delivery reports and recipient acknowledgment are separate states. A delivered email does not prove that someone read it.</p></details>
          <details><summary>What about location and privacy?</summary><p>Location is optional. If available, the recipient view shows its age and accuracy. Access uses a private link, so anyone with that link may be able to view it. Read our <a href="/privacy">Privacy</a> page for the data lifecycle and limitations.</p></details>
          <details><summary>Is SignalWord free?</summary><p>Yes. Alerts, trusted contacts, check-ins and all safety features are free. One optional, one-time Supporter purchase unlocks both Ocean and Lavender colour themes. It is not a subscription.</p></details>
          <details><summary>Can I download the app now?</summary><p>SignalWord is awaiting App Store review. Public download will be available after approval and release. For product questions, email <a href="mailto:support@signalword.app">support@signalword.app</a>. Please don’t include private alert links, passwords or precise locations.</p></details>
        </section>
      </main>
      <footer className="home-footer home-wrap">
        <a className="wordmark" href="/" aria-label="SignalWord home"><img src="/favicon.svg?v=3" width="26" height="26" alt="" /><span>SignalWord</span></a>
        <p>A little preparation. A person you trust.</p>
        <nav aria-label="Footer navigation"><a href="/privacy">Privacy</a><a href="/support">Support</a></nav>
      </footer>
    </div>
  )
}
