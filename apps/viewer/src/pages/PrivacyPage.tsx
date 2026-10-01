export function PrivacyPage() {
  return (
    <main className="information-shell">
      <header className="information-header">
        <a href="/" className="wordmark">SignalWord</a>
        <a href="/support">Support</a>
      </header>
      <article className="information-content">
        <div className="information-intro">
          <p className="eyebrow">Privacy</p>
        <h1>Your private phrase stays with iOS.</h1>
        <p className="lede">SignalWord is designed to notify your confirmed trusted contacts. It is not an emergency-dispatch service.</p>
        </div>

        <section className="information-section">
          <h2>What SignalWord does not collect</h2>
          <p>SignalWord does not receive, store, log, or upload your Vocal Shortcut phrase, its audio, or ordinary ambient audio.</p>
        </section>
        <section className="information-section">
          <h2>What an alert can include</h2>
          <p>After an alert, SignalWord may process your chosen display name, encrypted trusted-contact destination, alert status, and the latest available location with its timestamp and accuracy.</p>
        </section>
        <section className="information-section">
          <h2>Optional purchases</h2>
          <p>SignalWord offers a one-time supporter appearance purchase through RevenueCat and your app store. Billing uses a separate anonymous purchase identifier, transaction information, and SDK device information to provide purchases, restore entitlements, and analyse purchase activity. We do not attach your safety account, contact addresses, phrases, alert links, or location to RevenueCat. Safety features remain free. Store transaction records are separate from safety-account deletion; deleting your account does not refund a purchase. Contact support for billing-data questions.</p>
        </section>
        <section className="information-section">
          <h2>Retention</h2>
          <p>Location samples are scheduled for deletion 24 hours after resolution or expiry. Redacted delivery diagnostics are retained for no more than seven days. A separate recovery journal retains opaque account/contact identifiers and consent generations for at least 90 days so a backup restore cannot undo deletion or withdrawal. That journal does not contain contact addresses, locations or private alert links.</p>
        </section>
        <section className="information-section">
          <h2>Links and recipients</h2>
          <p>A contact viewer link is high-entropy, time-limited, and revocable. It is scoped to one event. SignalWord does not automatically contact police or emergency services.</p>
        </section>
        <section className="information-section information-section-emphasis">
          <h2>Delete your data</h2>
          <p>Use the in-app deletion flow to revoke viewer links, remove your profile and alert data, clear local storage, and sign out the device identity. Completion requires the recovery journal and local cleanup to succeed; interrupted requests may need a retry. A hashed completion receipt and the recovery journal remain to prevent deleted access from being restored. This page does not submit a deletion request.</p>
        </section>
      </article>
    </main>
  )
}
