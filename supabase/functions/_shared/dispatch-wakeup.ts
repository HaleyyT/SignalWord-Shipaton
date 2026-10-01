/** A failed wakeup never rolls back an accepted event. Scheduled dispatch recovers it. */
export async function wakeDispatch(url: string, secret: string, fetchImpl: typeof fetch = fetch): Promise<void> {
  if (!url || secret.length < 32) return;
  try {
    await fetchImpl(`${url.replace(/\/$/, '')}/functions/v1/dispatch-deliveries`, {
      method: 'POST', headers: { Authorization: `Bearer ${secret}` },
      signal: AbortSignal.timeout(1000), redirect: 'error',
    });
  } catch { /* Durable outbox and scheduled sweep remain authoritative. */ }
}
