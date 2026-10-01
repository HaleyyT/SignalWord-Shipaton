# Supabase backend

Use the Supabase CLI only after a project is linked locally. Keep schema changes in numbered migrations and test Row Level Security in `tests/`.

The initial migration establishes the V1 alert tables plus private confirmation-token and rate-limit storage. It enforces default-deny public access, owner-scoped Row Level Security, contact/event ownership, 256-bit token hashes, delivery idempotency and retry state, and bounded retention.

Retention runs hourly inside PostgreSQL through `pg_cron`; it calls the locked-down `purge_expired_alert_data()` function directly and therefore requires no URL or stored bearer secret. Apply migrations only to the development/test project first, then run `npm run test:db`. The pgTAP suite exercises authenticated user A/user B isolation, anonymous denial, ownership constraints, nullable provider IDs, lifecycle checks, retention, and cascade deletion.

The Day-2 walking skeleton currently deploys two routed Edge Functions:

- `user-api` — authenticated `POST /v1/alerts`
- `public-event`

`POST /v1/alerts` requires a user JWT and a UUID `Idempotency-Key` header. The
database RPC holds a per-user transaction advisory lock, then atomically reuses
or creates the event, hash-only viewer token, optional location, and one queued
delivery outbox row. The outbox stores the viewer capability only inside an
AES-256-GCM envelope whose versioned key comes from Edge Function secrets. The
raw viewer token is never returned to the iOS client or written to logs.

The fake adapter is constructible only in `development` or `test`. Production
starts with delivery unavailable and fails closed rather than accepting REAL
alerts until the real provider slice is configured. Real Resend dispatch,
contact confirmation, and webhook handling belong to that slice.

The delivery worker claims outbox rows using `FOR UPDATE SKIP LOCKED`, receives a
30-second lease, and records success or a bounded 1/5/15-minute retry schedule.
Four failed attempts become terminal. A worker crash leaves the encrypted row
recoverable after lease expiry.

Public viewer traffic is intentionally same-origin through
`apps/viewer/api/v1/public/events/[token].mjs`; no browser CORS permission is
required. Configure `SIGNALWORD_PUBLIC_EVENT_ORIGIN` to the deployed
`public-event` function. Apply IP-based throttling at the hosting firewall/API
gateway (recommended starting ceiling: 60 requests/minute/IP); token-only
application throttling is insufficient because attackers can rotate unknown
tokens. The public function still returns `429` transparently for upstream
limits. The user API reads request streams incrementally and rejects bodies over
16 KiB even when `Content-Length` is absent.

Migration ordering: `20260924010000_alert_api_walking_skeleton.sql` expects the
base six tables. Before exercising more than one distinct alert, apply the
database-hardening migration that replaces the original `NULLS NOT DISTINCT`
delivery constraint with a partial unique provider-message index. Without that
fix, the base schema permits only one queued delivery whose provider message ID
is null. The walking-skeleton migration does not duplicate that schema fix.

Run the function boundary tests with `npm run test:functions`. Run
`npm run test:db` with Docker Desktop active to compile migrations and execute
pgTAP before merging or deploying database changes.

Privileged server and delivery-provider secrets are configured with `supabase secrets set`; they must not appear in a repository file, iOS configuration, or web bundle.
