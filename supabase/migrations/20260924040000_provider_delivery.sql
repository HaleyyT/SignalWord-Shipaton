-- Crash-safe provider dispatch and authenticated webhook reconciliation.
-- Service-role workers receive ciphertext and decrypt it only in memory.

alter table public.contact_verification_deliveries
  add column provider_message_id text,
  add column last_attempt_at timestamptz,
  add column lease_owner uuid,
  add column lease_expires_at timestamptz,
  add constraint contact_verification_delivery_lease_complete check (
    (lease_owner is null and lease_expires_at is null)
    or (lease_owner is not null and lease_expires_at is not null)
  );

create unique index contact_verification_provider_message_unique_idx
  on public.contact_verification_deliveries (provider, provider_message_id)
  where provider_message_id is not null;

create table public.delivery_webhook_receipts (
  provider text not null check (provider = 'resend'),
  provider_event_id text not null,
  provider_message_id text not null,
  event_type text not null check (
    event_type in ('sent', 'delivered', 'bounced', 'complained', 'failed', 'delivery_delayed')
  ),
  received_at timestamptz not null default now(),
  primary key (provider, provider_event_id),
  constraint delivery_webhook_event_id_length check (char_length(provider_event_id) between 1 and 200),
  constraint delivery_webhook_message_id_length check (char_length(provider_message_id) between 1 and 200)
);

alter table public.delivery_webhook_receipts enable row level security;
revoke all on public.delivery_webhook_receipts from anon, authenticated;

drop function public.claim_alert_deliveries(uuid, integer);
create function public.claim_alert_deliveries(
  p_worker_id uuid,
  p_limit integer default 10
)
returns table (
  delivery_id uuid,
  event_id uuid,
  kind text,
  message_type text,
  provider text,
  provider_idempotency_key text,
  payload_ciphertext text,
  payload_key_version smallint,
  destination_ciphertext text,
  destination_key_version smallint,
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
  select claimed.id, claimed.alert_event_id, event.kind, claimed.message_type,
    claimed.provider, claimed.provider_idempotency_key,
    claimed.payload_ciphertext, claimed.payload_key_version,
    contact.destination_ciphertext, contact.destination_key_version,
    claimed.attempt_count
  from claimed
  join public.alert_events event on event.id = claimed.alert_event_id
  join public.trusted_contacts contact on contact.id = event.trusted_contact_id;
$$;

revoke all on function public.claim_alert_deliveries(uuid, integer) from public;
grant execute on function public.claim_alert_deliveries(uuid, integer) to service_role;

drop function public.finish_alert_delivery(uuid, uuid, boolean, text, text);
create function public.finish_alert_delivery(
  p_delivery_id uuid,
  p_worker_id uuid,
  p_succeeded boolean,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_retryable boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_attempt_count integer; v_max_attempts integer;
begin
  select attempt_count, max_attempts into v_attempt_count, v_max_attempts
  from public.alert_deliveries
  where id = p_delivery_id and lease_owner = p_worker_id
  for update;
  if not found then return false; end if;

  update public.alert_deliveries
  set status = case when p_succeeded then 'sent'
      when not p_retryable or v_attempt_count >= v_max_attempts then 'failed' else 'queued' end,
    provider_message_id = case when p_succeeded then pg_catalog.left(p_provider_message_id, 200) else provider_message_id end,
    last_error_code = case when p_succeeded then null else pg_catalog.left(p_error_code, 80) end,
    completed_at = case when not p_succeeded and (not p_retryable or v_attempt_count >= v_max_attempts)
      then now() else null end,
    next_attempt_at = case v_attempt_count when 1 then now() + interval '1 minute'
      when 2 then now() + interval '5 minutes' else now() + interval '15 minutes' end,
    lease_owner = null, lease_expires_at = null, updated_at = now()
  where id = p_delivery_id and lease_owner = p_worker_id;
  return found;
end;
$$;

revoke all on function public.finish_alert_delivery(uuid, uuid, boolean, text, text, boolean) from public;
grant execute on function public.finish_alert_delivery(uuid, uuid, boolean, text, text, boolean) to service_role;

create function public.claim_contact_verification_deliveries(
  p_worker_id uuid,
  p_limit integer default 10
)
returns table (
  delivery_id uuid,
  contact_id uuid,
  provider text,
  provider_idempotency_key text,
  payload_ciphertext text,
  payload_key_version smallint,
  destination_ciphertext text,
  destination_key_version smallint,
  attempt_count integer
)
language sql
security definer
set search_path = ''
as $$
  with candidates as (
    select delivery.id
    from public.contact_verification_deliveries delivery
    where delivery.status = 'queued'
      and delivery.attempt_count < delivery.max_attempts
      and delivery.next_attempt_at <= now()
      and (delivery.lease_expires_at is null or delivery.lease_expires_at <= now())
    order by delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit least(greatest(p_limit, 1), 50)
  ), claimed as (
    update public.contact_verification_deliveries delivery
    set lease_owner = p_worker_id, lease_expires_at = now() + interval '30 seconds',
      last_attempt_at = now(), attempt_count = delivery.attempt_count + 1,
      updated_at = now()
    from candidates where delivery.id = candidates.id
    returning delivery.*
  )
  select claimed.id, claimed.trusted_contact_id, claimed.provider,
    claimed.provider_idempotency_key, claimed.payload_ciphertext,
    claimed.payload_key_version, contact.destination_ciphertext,
    contact.destination_key_version, claimed.attempt_count
  from claimed
  join public.trusted_contacts contact on contact.id = claimed.trusted_contact_id;
$$;

revoke all on function public.claim_contact_verification_deliveries(uuid, integer) from public;
grant execute on function public.claim_contact_verification_deliveries(uuid, integer) to service_role;

create function public.finish_contact_verification_delivery(
  p_delivery_id uuid,
  p_worker_id uuid,
  p_succeeded boolean,
  p_provider_message_id text default null,
  p_error_code text default null,
  p_retryable boolean default true
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_attempt_count integer; v_max_attempts integer;
begin
  select attempt_count, max_attempts into v_attempt_count, v_max_attempts
  from public.contact_verification_deliveries
  where id = p_delivery_id and lease_owner = p_worker_id
  for update;
  if not found then return false; end if;

  update public.contact_verification_deliveries
  set status = case when p_succeeded then 'sent'
      when not p_retryable or v_attempt_count >= v_max_attempts then 'failed' else 'queued' end,
    provider_message_id = case when p_succeeded then pg_catalog.left(p_provider_message_id, 200) else provider_message_id end,
    last_error_code = case when p_succeeded then null else pg_catalog.left(p_error_code, 80) end,
    completed_at = case when not p_succeeded and (not p_retryable or v_attempt_count >= v_max_attempts)
      then now() else null end,
    next_attempt_at = case v_attempt_count when 1 then now() + interval '1 minute'
      when 2 then now() + interval '5 minutes' else now() + interval '15 minutes' end,
    lease_owner = null, lease_expires_at = null, updated_at = now()
  where id = p_delivery_id and lease_owner = p_worker_id;
  return found;
end;
$$;

revoke all on function public.finish_contact_verification_delivery(uuid, uuid, boolean, text, text, boolean) from public;
grant execute on function public.finish_contact_verification_delivery(uuid, uuid, boolean, text, text, boolean) to service_role;

create function public.apply_resend_webhook(
  p_provider_event_id text,
  p_provider_message_id text,
  p_event_type text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_inserted integer;
begin
  if pg_catalog.char_length(p_provider_event_id) not between 1 and 200
    or pg_catalog.char_length(p_provider_message_id) not between 1 and 200
    or p_event_type not in ('sent', 'delivered', 'bounced', 'complained', 'failed', 'delivery_delayed') then
    raise exception using errcode = '22023', message = 'INVALID_WEBHOOK_EVENT';
  end if;
  insert into public.delivery_webhook_receipts (
    provider, provider_event_id, provider_message_id, event_type
  ) values ('resend', p_provider_event_id, p_provider_message_id, p_event_type)
  on conflict do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then return false; end if;

  update public.alert_deliveries
  set status = case when p_event_type = 'delivered' then 'delivered'
      when p_event_type in ('bounced', 'complained', 'failed') then 'failed' else status end,
    completed_at = case when p_event_type in ('delivered', 'bounced', 'complained', 'failed') then now() else completed_at end,
    last_error_code = case when p_event_type in ('bounced', 'complained', 'failed')
      then upper(p_event_type) when p_event_type = 'delivered' then null else last_error_code end,
    updated_at = now()
  where provider = 'resend' and provider_message_id = p_provider_message_id;

  update public.contact_verification_deliveries
  set status = case when p_event_type = 'delivered' then 'delivered'
      when p_event_type in ('bounced', 'complained', 'failed') then 'failed' else status end,
    completed_at = case when p_event_type in ('delivered', 'bounced', 'complained', 'failed') then now() else completed_at end,
    last_error_code = case when p_event_type in ('bounced', 'complained', 'failed')
      then upper(p_event_type) when p_event_type = 'delivered' then null else last_error_code end,
    updated_at = now()
  where provider = 'resend' and provider_message_id = p_provider_message_id;
  return true;
end;
$$;

revoke all on function public.apply_resend_webhook(text, text, text) from public;
grant execute on function public.apply_resend_webhook(text, text, text) to service_role;
