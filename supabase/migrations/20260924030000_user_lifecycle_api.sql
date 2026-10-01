-- Authenticated contact and alert lifecycle operations.
-- Sensitive contact destinations and confirmation capabilities cross this
-- boundary only as ciphertext or one-way digests.

alter table public.trusted_contacts
  add column destination_key_version smallint;

-- Existing pre-encryption contacts cannot be trusted for delivery. Preserve the
-- row for audit/UI repair, but require the user to replace and reconfirm it.
update public.trusted_contacts
set status = 'disabled', confirmed_at = null, destination_key_version = 1
where destination_key_version is null;

alter table public.trusted_contacts
  alter column destination_key_version set not null,
  alter column destination_key_version set default 1,
  add constraint trusted_contact_destination_key_version_positive
    check (destination_key_version > 0);

create table public.contact_verification_deliveries (
  id uuid primary key default gen_random_uuid(),
  trusted_contact_id uuid not null references public.trusted_contacts(id) on delete cascade,
  provider text not null check (provider in ('fake', 'resend')),
  provider_idempotency_key text not null unique,
  payload_ciphertext text not null,
  payload_key_version smallint not null check (payload_key_version > 0),
  status text not null default 'queued' check (status in ('queued', 'sent', 'delivered', 'failed')),
  attempt_count integer not null default 0 check (attempt_count between 0 and 4),
  max_attempts integer not null default 4 check (max_attempts between 1 and 4),
  next_attempt_at timestamptz not null default now(),
  completed_at timestamptz,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contact_verification_delivery_completion_check check (
    (status in ('delivered', 'failed') and completed_at is not null)
    or (status in ('queued', 'sent') and completed_at is null)
  )
);

alter table public.contact_verification_deliveries enable row level security;
revoke all on public.contact_verification_deliveries from anon, authenticated;
create index contact_verification_deliveries_dispatch_idx
  on public.contact_verification_deliveries (next_attempt_at, created_at)
  where status = 'queued';

create or replace function public.create_or_replace_contact(
  p_user_id uuid,
  p_name text,
  p_channel text,
  p_destination_ciphertext text,
  p_destination_fingerprint text,
  p_destination_key_version integer,
  p_confirmation_token_hash bytea,
  p_confirmation_payload_ciphertext text,
  p_payload_key_version integer,
  p_delivery_provider text
)
returns table (
  contact_id uuid,
  contact_name text,
  contact_channel text,
  contact_status text,
  confirmation_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact public.trusted_contacts%rowtype;
  v_token_id uuid;
  v_expires_at timestamptz := now() + interval '30 minutes';
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(p_name)) not between 1 and 80
    or p_channel <> 'email'
    or pg_catalog.char_length(p_destination_ciphertext) < 24
    or pg_catalog.char_length(p_destination_fingerprint) <> 64
    or p_destination_key_version not between 1 and 32767
    or pg_catalog.octet_length(p_confirmation_token_hash) <> 32
    or pg_catalog.char_length(p_confirmation_payload_ciphertext) < 24
    or p_payload_key_version not between 1 and 32767
    or p_delivery_provider not in ('fake', 'resend') then
    raise exception using errcode = '22023', message = 'INVALID_CONTACT_CONFIGURATION';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 1));

  select * into v_contact from public.trusted_contacts where user_id = p_user_id for update;
  if found then
    update public.viewer_tokens token
      set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where event.trusted_contact_id = v_contact.id
        and token.alert_event_id = event.id;
    update public.trusted_contacts
      set name = pg_catalog.btrim(p_name), channel = p_channel,
        destination_ciphertext = p_destination_ciphertext,
        destination_fingerprint = p_destination_fingerprint,
        destination_key_version = p_destination_key_version::smallint,
        status = 'pending', confirmed_at = null
      where id = v_contact.id
      returning * into v_contact;
  else
    insert into public.trusted_contacts (
      user_id, name, channel, destination_ciphertext, destination_fingerprint,
      destination_key_version, status
    ) values (
      p_user_id, pg_catalog.btrim(p_name), p_channel,
      p_destination_ciphertext, p_destination_fingerprint,
      p_destination_key_version::smallint, 'pending'
    ) returning * into v_contact;
  end if;

  delete from public.contact_confirmation_tokens where trusted_contact_id = v_contact.id;
  insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at)
    values (v_contact.id, p_confirmation_token_hash, v_expires_at)
    returning id into v_token_id;
  insert into public.contact_verification_deliveries (
    trusted_contact_id, provider, provider_idempotency_key,
    payload_ciphertext, payload_key_version
  ) values (
    v_contact.id, p_delivery_provider,
    'contact/' || v_contact.id::text || '/verification/' || v_token_id::text,
    p_confirmation_payload_ciphertext, p_payload_key_version::smallint
  );

  return query select v_contact.id, v_contact.name, v_contact.channel,
    v_contact.status, v_expires_at;
end;
$$;

revoke all on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) from public;
grant execute on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) to authenticated;

create or replace function public.get_my_contact(p_user_id uuid)
returns table (contact_id uuid, contact_name text, contact_channel text, contact_status text)
language sql
stable
security definer
set search_path = ''
as $$
  select contact.id, contact.name, contact.channel, contact.status
  from public.trusted_contacts contact
  where contact.user_id = p_user_id and (select auth.uid()) = p_user_id
  limit 1;
$$;

revoke all on function public.get_my_contact(uuid) from public;
grant execute on function public.get_my_contact(uuid) to authenticated;

create or replace function public.disable_contact(p_user_id uuid, p_contact_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  update public.trusted_contacts
    set status = 'disabled', confirmed_at = null
    where id = p_contact_id and user_id = p_user_id and status <> 'disabled';
  if found then
    delete from public.contact_confirmation_tokens where trusted_contact_id = p_contact_id;
    update public.viewer_tokens token set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where event.trusted_contact_id = p_contact_id and token.alert_event_id = event.id;
    return true;
  end if;
  return exists(select 1 from public.trusted_contacts where id = p_contact_id and user_id = p_user_id);
end;
$$;

revoke all on function public.disable_contact(uuid, uuid) from public;
grant execute on function public.disable_contact(uuid, uuid) to authenticated;

create or replace function public.confirm_contact(p_token_hash bytea)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_contact_id uuid;
begin
  update public.contact_confirmation_tokens
    set consumed_at = now()
    where token_hash = p_token_hash and consumed_at is null and expires_at > now()
    returning trusted_contact_id into v_contact_id;
  if v_contact_id is null then return false; end if;
  update public.trusted_contacts
    set status = 'confirmed', confirmed_at = now()
    where id = v_contact_id and status = 'pending';
  return found;
end;
$$;

revoke all on function public.confirm_contact(bytea) from public;
grant execute on function public.confirm_contact(bytea) to anon, authenticated;

create or replace function public.append_alert_location(
  p_user_id uuid, p_event_id uuid, p_location jsonb
)
returns table (accepted boolean, received_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare v_event public.alert_events%rowtype; v_received_at timestamptz := now();
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  select * into v_event from public.alert_events
    where id = p_event_id and user_id = p_user_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'EVENT_NOT_FOUND'; end if;
  if v_event.state not in ('pending', 'active') or v_event.expires_at <= now() then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  if p_location is null
    or (p_location->>'capturedAt') is null
    or (p_location->>'latitude')::double precision not between -90 and 90
    or (p_location->>'longitude')::double precision not between -180 and 180
    or (p_location->>'horizontalAccuracyM')::double precision not between 0 and 100000
    or (p_location->>'capturedAt')::timestamptz < now() - interval '24 hours'
    or (p_location->>'capturedAt')::timestamptz > now() + interval '5 minutes' then
    return query select false, v_received_at; return;
  end if;
  if exists(select 1 from public.location_samples sample
    where sample.alert_event_id = p_event_id and sample.received_at > now() - interval '5 seconds') then
    return query select false, v_received_at; return;
  end if;
  insert into public.location_samples (
    alert_event_id, captured_at, received_at, latitude, longitude,
    horizontal_accuracy_m, expires_at
  ) values (
    p_event_id, (p_location->>'capturedAt')::timestamptz, v_received_at,
    (p_location->>'latitude')::double precision,
    (p_location->>'longitude')::double precision,
    (p_location->>'horizontalAccuracyM')::double precision,
    least(v_event.expires_at, now() + interval '24 hours')
  );
  return query select true, v_received_at;
end;
$$;

revoke all on function public.append_alert_location(uuid, uuid, jsonb) from public;
grant execute on function public.append_alert_location(uuid, uuid, jsonb) to authenticated;

create or replace function public.get_alert_status(p_user_id uuid, p_event_id uuid)
returns table (
  event_id uuid, event_kind text, event_state text, triggered_at timestamptz,
  resolved_at timestamptz, delivery_status text, latest_location_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select event.id, event.kind, event.state, event.triggered_at, event.resolved_at,
    coalesce(delivery.status, 'queued'), location.captured_at
  from public.alert_events event
  left join lateral (
    select d.status from public.alert_deliveries d where d.alert_event_id = event.id
    order by d.created_at desc limit 1
  ) delivery on true
  left join lateral (
    select l.captured_at from public.location_samples l where l.alert_event_id = event.id
    order by l.received_at desc limit 1
  ) location on true
  where event.id = p_event_id and event.user_id = p_user_id
    and (select auth.uid()) = p_user_id;
$$;

revoke all on function public.get_alert_status(uuid, uuid) from public;
grant execute on function public.get_alert_status(uuid, uuid) to authenticated;

create or replace function public.resolve_alert(p_user_id uuid, p_event_id uuid)
returns table (event_id uuid, event_state text, event_resolved_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
declare v_event public.alert_events%rowtype; v_initial public.alert_deliveries%rowtype;
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  select * into v_event from public.alert_events
    where id = p_event_id and user_id = p_user_id for update;
  if not found then raise exception using errcode = 'P0002', message = 'EVENT_NOT_FOUND'; end if;
  if v_event.state = 'expired' then
    raise exception using errcode = 'P0001', message = 'EVENT_NOT_ACTIVE';
  end if;
  if v_event.state <> 'resolved' then
    update public.alert_events set state = 'resolved', resolved_at = now(),
      expires_at = least(expires_at, now() + interval '24 hours')
      where id = p_event_id returning * into v_event;
    select * into v_initial from public.alert_deliveries
      where alert_event_id = p_event_id and message_type = 'initial'
      order by created_at limit 1;
    if found then
      insert into public.alert_deliveries (
        alert_event_id, provider, provider_idempotency_key, message_type,
        payload_ciphertext, payload_key_version
      ) values (
        p_event_id, v_initial.provider, 'alert/' || p_event_id::text || '/resolved', 'resolved',
        v_initial.payload_ciphertext, v_initial.payload_key_version
      ) on conflict (provider_idempotency_key) do nothing;
    end if;
  end if;
  return query select v_event.id, v_event.state, v_event.resolved_at;
end;
$$;

revoke all on function public.resolve_alert(uuid, uuid) from public;
grant execute on function public.resolve_alert(uuid, uuid) to authenticated;

create or replace function public.delete_my_account(p_user_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare v_deletion_id uuid := gen_random_uuid();
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  delete from auth.users where id = p_user_id;
  return v_deletion_id;
end;
$$;

revoke all on function public.delete_my_account(uuid) from public;
grant execute on function public.delete_my_account(uuid) to authenticated;

-- Retention includes the confirmation outbox without retaining delivered
-- recipient metadata indefinitely.
create or replace function public.purge_expired_alert_data()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.alert_events set state = 'expired'
    where state in ('pending', 'active') and expires_at <= now();
  delete from public.location_samples where expires_at <= now();
  delete from public.viewer_tokens where expires_at <= now() or revoked_at is not null;
  delete from public.contact_confirmation_tokens where expires_at <= now() or consumed_at is not null;
  delete from public.rate_limit_buckets where expires_at <= now();
  delete from public.alert_deliveries where created_at <= now() - interval '7 days'
    and status in ('delivered', 'failed');
  delete from public.contact_verification_deliveries where created_at <= now() - interval '7 days'
    and status in ('delivered', 'failed');
end;
$$;

revoke all on function public.purge_expired_alert_data() from public;
