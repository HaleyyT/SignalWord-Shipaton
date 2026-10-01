# Development monitoring update

The free Healthchecks mode uses two distinct secrets: `OPERATIONS_PING_URL` and `HEARTBEAT_URL`. See [current setup and acceptance](../../docs/release-readiness/MONITORING_SETUP.md). The earlier webhook instructions below describe the optional legacy mode only. Hosting and email acceptance are separate from local tests.

# Development operational monitor

The development Worker is provisioned and scheduled every minute; complete hosted acceptance is still pending. See the current release-readiness report for the verified deployment and drill evidence. Legacy webhook mode requires an operator-owned Cloudflare account, a Healthchecks check and an HTTPS incident receiver. Confirm account/cost settings before activation. Do not enable GitHub scheduled monitoring and Cloudflare incident notifications simultaneously unless duplicate notifications are intended.

1. Deploy the `operational-health` Edge Function to the development project with its dedicated `MONITOR_SECRET` (random, at least 32 characters). Never give an external monitor a Supabase service-role key.
2. Configure Worker secrets `MONITOR_SECRET`, `OPERATOR_WEBHOOK`, and `HEARTBEAT_URL`. Configure `BACKEND_ORIGIN` to the development Supabase origin. These values must not enter Git or command output.
3. Deploy this Worker using the checked-in Wrangler configuration after explicit activation approval. Its one-minute schedule addresses one Durable Object, which serializes probes and remembers the last successfully reported state.
4. Configure the independent Healthchecks check for a one-minute period and a two-minute grace. Verify an alert arrives when this worker is stopped. A green HTTP request is not evidence that an operator received a notification.
5. Inject a development-only queue incident, verify one notification, verify no repeated notifications while unchanged, then resolve and verify one recovery notification. A failed notification retries on the next tick. Delivery can duplicate if the receiver accepts a request but its response is lost; the receiver should group incidents by service.
6. Rotate with `MONITOR_PREVIOUS_SECRET`: configure new + previous on the Edge Function, switch the monitor, verify, then remove the previous secret. Empty/short secrets fail closed.

The endpoint returns fixed aggregate problem codes only. It cannot read accounts, contact destinations, recipient links or locations on behalf of the external caller. The Supabase service key stays inside the Edge Function. Incident receiver and heartbeat URLs are sensitive and must not be logged.

The monitor does not claim physical-device crash coverage. Sentry integration and a signed-device crash drill are separate release gates. Hosted ingress restrictions, abuse thresholds, webhook-lag instrumentation and complete restore protection must also be verified before enrollment.
