-- Day 2 walking skeleton: transactional alert creation and token-scoped projection.
-- This migration is additive so the schema-hardening branch can be applied first
-- or reconciled independently. Raw viewer tokens are hashed for lookup and an
-- encrypted copy is held only in the crash-recoverable delivery outbox.

alter table public.alert_deliveries
  add column payload_ciphertext text,
  add column payload_key_version smallint,
  add column lease_owner uuid,
  add column lease_expires_at timestamptz,
  add constraint alert_delivery_lease_is_complete check (
    (lease_owner is null and lease_expires_at is null) or
    (lease_owner is not null and lease_expires_at is not null)
  );

-- Pre-outbox queued rows cannot be recovered because their raw capability was
-- never persisted. Fail them explicitly instead of pretending they can send or
-- letting a NOT NULL migration fail on an existing environment.
update public.alert_deliveries
set status = 'failed',
  completed_at = now(),
  last_error_code = 'LEGACY_OUTBOX_UNRECOVERABLE',
  payload_ciphertext = 'legacy-unrecoverable',
  payload_key_version = 1,
  updated_at = now()
where payload_ciphertext is null;

alter table public.alert_deliveries
  alter column payload_ciphertext set not null,
  alter column payload_key_version set not null,
  add constraint alert_delivery_payload_key_version_positive
    check (payload_key_version > 0);

create index alert_deliveries_dispatch_idx
  on public.alert_deliveries (next_attempt_at, created_at)
  where status = 'queued';

create or replace function public.create_or_reuse_alert(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_kind text,
  p_trigger_method text,
  p_viewer_token text,
  p_delivery_provider text,
  p_delivery_payload_ciphertext text,
  p_delivery_payload_key_version integer,
  p_location jsonb default null
)
returns table (
  event_id uuid,
  event_state text,
  delivery_status text,
  server_triggered_at timestamptz,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact_id uuid;
  v_event public.alert_events%rowtype;
  v_delivery_status text;
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;

  -- Serializes both same-key retries and distinct invocations inside the cooldown.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

  select * into v_event
  from public.alert_events
  where user_id = p_user_id and idempotency_key = p_idempotency_key;

  if found then
    select status into v_delivery_status
    from public.alert_deliveries
    where alert_event_id = v_event.id
    order by updated_at desc, created_at desc
    limit 1;

    return query select v_event.id, v_event.state, coalesce(v_delivery_status, 'queued'),
      v_event.triggered_at, true;
    return;
  end if;

  select id into v_contact_id
  from public.trusted_contacts
  where user_id = p_user_id and status = 'confirmed'
  order by created_at desc
  limit 1;

  if v_contact_id is null then
    raise exception using errcode = 'P0001', message = 'CONTACT_NOT_CONFIRMED';
  end if;

  if p_delivery_provider not in ('fake', 'resend') or
    pg_catalog.char_length(p_delivery_payload_ciphertext) < 24 or
    p_delivery_payload_key_version < 1 or p_delivery_payload_key_version > 32767 then
    raise exception using errcode = '22023', message = 'INVALID_DELIVERY_CONFIGURATION';
  end if;

  -- A rate-limit decision persists in the event ledger and cannot be bypassed by
  -- moving the request between Edge Function instances.
  if (
    select count(*) from public.alert_events
    where user_id = p_user_id and kind = p_kind
      and triggered_at >= now() - interval '1 minute'
  ) >= 10 then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  select * into v_event
  from public.alert_events
  where user_id = p_user_id
    and kind = p_kind
    and state in ('pending', 'active')
    and triggered_at >= now() - interval '60 seconds'
  order by triggered_at desc
  limit 1;

  if found then
    select status into v_delivery_status
    from public.alert_deliveries
    where alert_event_id = v_event.id
    order by updated_at desc, created_at desc
    limit 1;

    return query select v_event.id, v_event.state, coalesce(v_delivery_status, 'queued'),
      v_event.triggered_at, true;
    return;
  end if;

  insert into public.alert_events (
    user_id, trusted_contact_id, idempotency_key, kind, state, trigger_method
  ) values (
    p_user_id, v_contact_id, p_idempotency_key, p_kind, 'active', p_trigger_method
  ) returning * into v_event;

  insert into public.viewer_tokens (alert_event_id, token_hash, expires_at)
  values (
    v_event.id,
    extensions.digest(pg_catalog.convert_to(p_viewer_token, 'UTF8'), 'sha256'),
    least(v_event.expires_at, now() + interval '24 hours')
  );

  insert into public.alert_deliveries (
    alert_event_id, provider, provider_idempotency_key, message_type,
    status, payload_ciphertext, payload_key_version
  ) values (
    v_event.id, p_delivery_provider, 'alert/' || v_event.id::text || '/initial', 'initial', 'queued',
    p_delivery_payload_ciphertext, p_delivery_payload_key_version::smallint
  )
  returning status into v_delivery_status;

  if p_location is not null then
    insert into public.location_samples (
      alert_event_id, captured_at, latitude, longitude,
      horizontal_accuracy_m, expires_at
    ) values (
      v_event.id,
      (p_location->>'capturedAt')::timestamptz,
      (p_location->>'latitude')::double precision,
      (p_location->>'longitude')::double precision,
      (p_location->>'horizontalAccuracyM')::double precision,
      least(v_event.expires_at, now() + interval '24 hours')
    );
  end if;

  return query select v_event.id, v_event.state, v_delivery_status,
    v_event.triggered_at, false;
end;
$$;

revoke all on function public.create_or_reuse_alert(uuid, uuid, text, text, text, text, text, integer, jsonb) from public;
grant execute on function public.create_or_reuse_alert(uuid, uuid, text, text, text, text, text, integer, jsonb) to authenticated;

create or replace function public.get_public_event(p_token_hash bytea)
returns table (projection jsonb)
language sql
stable
security definer
set search_path = ''
as $$
  with matching_event as (
    select event.id, event.kind, event.state, event.triggered_at,
      event.resolved_at, profile.display_name
    from public.viewer_tokens token
    join public.alert_events event on event.id = token.alert_event_id
    join public.profiles profile on profile.id = event.user_id
    where token.token_hash = p_token_hash
      and token.revoked_at is null
      and token.expires_at > now()
      and event.expires_at > now()
    limit 1
  ), latest_location as (
    select sample.*
    from public.location_samples sample
    join matching_event event on event.id = sample.alert_event_id
    where sample.expires_at > now()
    order by sample.received_at desc
    limit 1
  )
  select jsonb_strip_nulls(jsonb_build_object(
    'kind', event.kind,
    'displayName', event.display_name,
    'state', event.state,
    'triggeredAt', event.triggered_at,
    'lastUpdatedAt', greatest(event.triggered_at, coalesce(event.resolved_at, event.triggered_at),
      coalesce(location.received_at, event.triggered_at)),
    'location', case when location.id is null then null else jsonb_build_object(
      'latitude', location.latitude,
      'longitude', location.longitude,
      'horizontalAccuracyM', location.horizontal_accuracy_m,
      'capturedAt', location.captured_at,
      'freshness', case
        when location.captured_at between now() - interval '30 seconds' and now() + interval '5 minutes' then 'live'
        when location.captured_at between now() - interval '2 minutes' and now() + interval '5 minutes' then 'recent'
        else 'stale'
      end
    ) end,
    'guidance', jsonb_build_object(
      'summary', format(
        'Contact %s now. If you believe there is immediate danger, call the appropriate local emergency number.',
        event.display_name
      )
    )
  )) as projection
  from matching_event event
  left join latest_location location on true;
$$;

revoke all on function public.get_public_event(bytea) from public;
grant execute on function public.get_public_event(bytea) to anon, authenticated;

create or replace function public.claim_alert_deliveries(
  p_worker_id uuid,
  p_limit integer default 10
)
returns table (
  delivery_id uuid,
  event_id uuid,
  kind text,
  provider text,
  provider_idempotency_key text,
  payload_ciphertext text,
  payload_key_version smallint,
  attempt_count integer
)
language sql
security definer
set search_path = ''
as $$
  with candidates as (
    select delivery.id
    from public.alert_deliveries delivery
    where delivery.status = 'queued'
      and delivery.attempt_count < delivery.max_attempts
      and delivery.next_attempt_at <= now()
      and (delivery.lease_expires_at is null or delivery.lease_expires_at <= now())
    order by delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit least(greatest(p_limit, 1), 50)
  ), claimed as (
    update public.alert_deliveries delivery
    set lease_owner = p_worker_id,
      lease_expires_at = now() + interval '30 seconds',
      last_attempt_at = now(),
      attempt_count = delivery.attempt_count + 1,
      updated_at = now()
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  )
  select claimed.id, claimed.alert_event_id, event.kind, claimed.provider,
    claimed.provider_idempotency_key,
    claimed.payload_ciphertext, claimed.payload_key_version, claimed.attempt_count
  from claimed
  join public.alert_events event on event.id = claimed.alert_event_id;
$$;

revoke all on function public.claim_alert_deliveries(uuid, integer) from public;
grant execute on function public.claim_alert_deliveries(uuid, integer) to service_role;

create or replace function public.finish_alert_delivery(
  p_delivery_id uuid,
  p_worker_id uuid,
  p_succeeded boolean,
  p_provider_message_id text default null,
  p_error_code text default null
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempt_count integer;
  v_max_attempts integer;
begin
  select attempt_count, max_attempts into v_attempt_count, v_max_attempts
  from public.alert_deliveries
  where id = p_delivery_id and lease_owner = p_worker_id
  for update;

  if not found then return false; end if;

  update public.alert_deliveries
  set status = case when p_succeeded then 'sent'
      when v_attempt_count >= v_max_attempts then 'failed' else 'queued' end,
    provider_message_id = case when p_succeeded then p_provider_message_id else provider_message_id end,
    last_error_code = case when p_succeeded then null else pg_catalog.left(p_error_code, 80) end,
    completed_at = case when p_succeeded then null
      when v_attempt_count >= v_max_attempts then now() else null end,
    next_attempt_at = case v_attempt_count
      when 1 then now() + interval '1 minute'
      when 2 then now() + interval '5 minutes'
      else now() + interval '15 minutes'
    end,
    lease_owner = null,
    lease_expires_at = null,
    updated_at = now()
  where id = p_delivery_id and lease_owner = p_worker_id;

  return found;
end;
$$;

revoke all on function public.finish_alert_delivery(uuid, uuid, boolean, text, text) from public;
grant execute on function public.finish_alert_delivery(uuid, uuid, boolean, text, text) to service_role;
