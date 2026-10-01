export function SupportPage() {
  return (
    <main className="information-shell">
      <header className="information-header">
        <a href="/" className="wordmark">SignalWord</a>
        <a href="/privacy">Privacy</a>
      </header>
      <article className="information-content">
        <div className="information-intro">
          <p className="eyebrow">Support</p>
        <h1>Use a safe route to get help.</h1>
        <p className="lede">SignalWord helps notify a trusted contact. It does not dispatch emergency services or guarantee delivery.</p>
        </div>

        <section className="information-section information-section-emphasis">
          <h2>If you believe someone is in immediate danger</h2>
          <p>Contact the appropriate local emergency service. Do not wait for an alert link or location update.</p>
        </section>
        <section className="information-section">
          <h2>Before relying on SignalWord</h2>
          <p>Confirm your trusted contact, check Setup &amp; readiness, and practise a TEST alert together on your own device. Delivery requires a network connection and can fail.</p>
        </section>
        <section className="information-section">
          <h2>Report a product problem</h2>
          <p>For non-urgent product support, email us with the app version and a description of the problem. Do not include private phrases, contact details, alert links, passwords or precise locations.</p>
          <a className="action-link" href="mailto:support@signalword.app">Email SignalWord support</a>
        </section>
        <section className="information-section">
          <h2>Report a security concern</h2>
          <p>Report security concerns privately by email. Describe the issue without sending account credentials or live alert links. We can arrange a safe way to share further details.</p>
          <a className="action-link" href="mailto:support@signalword.app?subject=SignalWord%20security%20report">Report a security concern</a>
        </section>
      </article>
    </main>
  )
}
