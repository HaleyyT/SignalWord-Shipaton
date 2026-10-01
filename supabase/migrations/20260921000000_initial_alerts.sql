-- SignalWord V1: private alert data, created only through trusted Edge Functions.
-- No raw phrase, audio, viewer token, or contact destination is exposed publicly.

create extension if not exists pgcrypto;
create extension if not exists pg_cron;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 80),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.trusted_contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  channel text not null check (channel in ('email', 'sms')),
  destination_ciphertext text not null,
  destination_fingerprint text not null,
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'disabled')),
  confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint one_contact_per_user unique (user_id),
  constraint trusted_contacts_id_user_key unique (id, user_id),
  constraint confirmed_contact_has_timestamp check (
    (status = 'pending' and confirmed_at is null)
    or (status = 'confirmed' and confirmed_at is not null)
    or status = 'disabled'
  )
);

create unique index trusted_contacts_user_destination_key
  on public.trusted_contacts (user_id, destination_fingerprint);

create table public.alert_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  trusted_contact_id uuid not null,
  idempotency_key uuid not null,
  kind text not null check (kind in ('test', 'real')),
  state text not null default 'pending' check (state in ('pending', 'active', 'resolved', 'expired')),
  trigger_method text not null check (trigger_method in ('vocalShortcut', 'siri', 'actionButton', 'manual')),
  triggered_at timestamptz not null default now(),
  resolved_at timestamptz,
  expires_at timestamptz not null default (now() + interval '24 hours'),
  constraint alert_events_user_idempotency_key unique (user_id, idempotency_key),
  constraint alert_events_contact_owner_fk
    foreign key (trusted_contact_id, user_id)
    references public.trusted_contacts (id, user_id)
    on delete cascade,
  constraint alert_events_lifecycle_timestamp_check check (
    (state = 'resolved' and resolved_at is not null)
    or (state <> 'resolved' and resolved_at is null)
  ),
  constraint alert_events_expiry_after_trigger_check check (expires_at > triggered_at),
  constraint alert_events_resolution_order_check check (
    resolved_at is null or resolved_at >= triggered_at
  )
);

create index alert_events_user_triggered_at_idx
  on public.alert_events (user_id, triggered_at desc);
create index alert_events_active_expiry_idx
  on public.alert_events (expires_at) where state <> 'resolved';

create table public.location_samples (
  id bigint generated always as identity primary key,
  alert_event_id uuid not null references public.alert_events(id) on delete cascade,
  captured_at timestamptz not null,
  received_at timestamptz not null default now(),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  horizontal_accuracy_m double precision not null check (horizontal_accuracy_m >= 0 and horizontal_accuracy_m <= 100000),
  expires_at timestamptz not null
);

create index location_samples_event_received_at_idx
  on public.location_samples (alert_event_id, received_at desc);
create index location_samples_expiry_idx on public.location_samples (expires_at);

create table public.alert_deliveries (
  id uuid primary key default gen_random_uuid(),
  alert_event_id uuid not null references public.alert_events(id) on delete cascade,
  provider text not null,
  provider_message_id text,
  provider_idempotency_key text not null,
  message_type text not null default 'initial' check (message_type in ('initial', 'resolved')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  max_attempts integer not null default 4 check (max_attempts between 1 and 4),
  next_attempt_at timestamptz not null default now(),
  last_attempt_at timestamptz,
  completed_at timestamptz,
  status text not null default 'queued' check (status in ('queued', 'sent', 'delivered', 'failed')),
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint alert_deliveries_attempt_bound_check check (attempt_count <= max_attempts),
  constraint alert_deliveries_completion_check check (
    (status in ('delivered', 'failed') and completed_at is not null)
    or (status in ('queued', 'sent') and completed_at is null)
  ),
  constraint alert_deliveries_provider_idempotency_key unique (provider_idempotency_key),
  constraint alert_deliveries_event_message_provider_key
    unique (alert_event_id, message_type, provider)
);

create index alert_deliveries_event_idx on public.alert_deliveries (alert_event_id);
create index alert_deliveries_retry_idx
  on public.alert_deliveries (next_attempt_at)
  where status = 'queued';
create unique index alert_deliveries_provider_message_unique_idx
  on public.alert_deliveries (provider, provider_message_id)
  where provider_message_id is not null;

create table public.viewer_tokens (
  id uuid primary key default gen_random_uuid(),
  alert_event_id uuid not null references public.alert_events(id) on delete cascade,
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

create index viewer_tokens_expiry_idx on public.viewer_tokens (expires_at);

create table public.contact_confirmation_tokens (
  id uuid primary key default gen_random_uuid(),
  trusted_contact_id uuid not null references public.trusted_contacts(id) on delete cascade,
  token_hash bytea not null unique check (octet_length(token_hash) = 32),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now(),
  constraint contact_confirmation_expiry_check check (expires_at > created_at),
  constraint contact_confirmation_consumed_order_check check (
    consumed_at is null or consumed_at >= created_at
  )
);

create index contact_confirmation_tokens_expiry_idx
  on public.contact_confirmation_tokens (expires_at)
  where consumed_at is null;

-- Subjects are irreversible HMAC/SHA-256 digests. Raw email addresses, IP
-- addresses, viewer tokens, and user identifiers must never be stored here.
create table public.rate_limit_buckets (
  scope text not null check (scope in ('user', 'destination', 'ip', 'viewer_token')),
  subject_hash bytea not null check (octet_length(subject_hash) = 32),
  window_started_at timestamptz not null,
  request_count integer not null default 1 check (request_count > 0),
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (scope, subject_hash, window_started_at),
  constraint rate_limit_expiry_check check (expires_at > window_started_at)
);

create index rate_limit_buckets_expiry_idx on public.rate_limit_buckets (expires_at);

alter table public.profiles enable row level security;
alter table public.trusted_contacts enable row level security;
alter table public.alert_events enable row level security;
alter table public.location_samples enable row level security;
alter table public.alert_deliveries enable row level security;
alter table public.viewer_tokens enable row level security;
alter table public.contact_confirmation_tokens enable row level security;
alter table public.rate_limit_buckets enable row level security;

create policy "profiles are visible to their owner"
  on public.profiles for select to authenticated
  using ((select auth.uid()) = id);
create policy "profiles can be created by their owner"
  on public.profiles for insert to authenticated
  with check ((select auth.uid()) = id);
create policy "profiles can be updated by their owner"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "contacts are visible to their owner"
  on public.trusted_contacts for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "events are visible to their owner"
  on public.alert_events for select to authenticated
  using ((select auth.uid()) = user_id);
create policy "locations are visible to their event owner"
  on public.location_samples for select to authenticated
  using (exists (
    select 1 from public.alert_events event
    where event.id = location_samples.alert_event_id
      and event.user_id = (select auth.uid())
  ));
create policy "delivery diagnostics are visible to their event owner"
  on public.alert_deliveries for select to authenticated
  using (exists (
    select 1 from public.alert_events event
    where event.id = alert_deliveries.alert_event_id
      and event.user_id = (select auth.uid())
  ));

grant select, insert, update on public.profiles to authenticated;
grant select on public.trusted_contacts to authenticated;
grant select on public.alert_events to authenticated;
grant select on public.location_samples to authenticated;
grant select on public.alert_deliveries to authenticated;

-- Public links are resolved only by the public-event Edge Function. There is no
-- direct client policy for viewer_tokens.
revoke all on public.viewer_tokens from anon, authenticated;
revoke all on public.contact_confirmation_tokens from anon, authenticated;
revoke all on public.rate_limit_buckets from anon, authenticated;
revoke all on public.trusted_contacts from anon;
revoke all on public.alert_events from anon;
revoke all on public.location_samples from anon;
revoke all on public.alert_deliveries from anon;
revoke all on public.profiles from anon;

create or replace function public.purge_expired_alert_data()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.alert_events
    set state = 'expired'
    where state in ('pending', 'active')
      and expires_at <= now();

  delete from public.location_samples where expires_at <= now();
  delete from public.viewer_tokens where expires_at <= now() or revoked_at is not null;
  delete from public.contact_confirmation_tokens
    where expires_at <= now() or consumed_at is not null;
  delete from public.rate_limit_buckets where expires_at <= now();
  delete from public.alert_deliveries
    where created_at <= now() - interval '7 days'
      and status in ('delivered', 'failed');
end;
$$;

revoke all on function public.purge_expired_alert_data() from public;

-- pg_cron runs this database-local statement as the migration owner. No URL,
-- bearer token, Vault entry, or other secret is required for retention.
select cron.schedule(
  'signalword-hourly-retention',
  '5 * * * *',
  'select public.purge_expired_alert_data()'
)
where not exists (
  select 1 from cron.job where jobname = 'signalword-hourly-retention'
);
