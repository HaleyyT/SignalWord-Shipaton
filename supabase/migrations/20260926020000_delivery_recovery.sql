-- Snapshot destinations before a mutable contact can be replaced.
alter table public.alert_deliveries add column destination_snapshot text, add column destination_version smallint;
alter table public.contact_verification_deliveries add column destination_snapshot text, add column destination_version smallint;
update public.alert_deliveries d set destination_snapshot=c.destination_ciphertext, destination_version=c.destination_key_version
 from public.alert_events e join public.trusted_contacts c on c.id=e.trusted_contact_id where e.id=d.alert_event_id;
update public.contact_verification_deliveries d set destination_snapshot=c.destination_ciphertext, destination_version=c.destination_key_version
 from public.trusted_contacts c where c.id=d.trusted_contact_id;

create function public.snapshot_delivery_destination() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='alert_deliveries' then
  select c.destination_ciphertext,c.destination_key_version into new.destination_snapshot,new.destination_version
  from public.alert_events e join public.trusted_contacts c on c.id=e.trusted_contact_id where e.id=new.alert_event_id;
 else
  select destination_ciphertext,destination_key_version into new.destination_snapshot,new.destination_version
  from public.trusted_contacts where id=new.trusted_contact_id;
 end if;
 return new;
end $$;
revoke all on function public.snapshot_delivery_destination() from public;
create trigger snapshot_alert_destination before insert on public.alert_deliveries for each row execute function public.snapshot_delivery_destination();
create trigger snapshot_confirmation_destination before insert on public.contact_verification_deliveries for each row execute function public.snapshot_delivery_destination();

create function public.invalidate_contact_deliveries() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='disabled' or new.destination_ciphertext is distinct from old.destination_ciphertext then
  update public.alert_deliveries d set status='failed',completed_at=now(),last_error_code='CONTACT_WITHDRAWN',lease_owner=null,lease_expires_at=null
  from public.alert_events e where e.id=d.alert_event_id and e.trusted_contact_id=old.id and d.status='queued';
 end if;
 if new.status='disabled' or new.destination_ciphertext is distinct from old.destination_ciphertext then
  update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='CONTACT_REPLACED',lease_owner=null,lease_expires_at=null
  where trusted_contact_id=old.id and status='queued';
 end if;
 return new;
end $$;
revoke all on function public.invalidate_contact_deliveries() from public;
create trigger invalidate_contact_delivery before update on public.trusted_contacts for each row execute function public.invalidate_contact_deliveries();

create function public.recover_expired_delivery_leases() returns void language plpgsql security definer set search_path='' as $$
begin
 update public.alert_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (attempt_count>=max_attempts or created_at<now()-interval '23 hours');
 update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (attempt_count>=max_attempts or created_at<now()-interval '30 minutes');
end $$;
revoke all on function public.recover_expired_delivery_leases() from public;
grant execute on function public.recover_expired_delivery_leases() to service_role;
select cron.schedule('signalword-delivery-lease-recovery','* * * * *','select public.recover_expired_delivery_leases()');
create or replace function public.claim_alert_deliveries(
  p_worker_id uuid,
  p_limit integer default 1
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
      and delivery.created_at > now() - interval '23 hours'
      and exists (select 1 from public.alert_events e join public.trusted_contacts c on c.id=e.trusted_contact_id
        where e.id=delivery.alert_event_id and e.expires_at>now() and c.status='confirmed')
      and (delivery.message_type='initial' or exists (select 1 from public.alert_deliveries initial
        where initial.alert_event_id=delivery.alert_event_id and initial.message_type='initial' and initial.status in ('sent','delivered')))
      and delivery.attempt_count < delivery.max_attempts
      and delivery.next_attempt_at <= now()
      and (delivery.lease_expires_at is null or delivery.lease_expires_at <= now())
    order by (select e.kind='real' from public.alert_events e where e.id=delivery.alert_event_id) desc, delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit least(greatest(p_limit, 1), 3)
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
    claimed.destination_snapshot, claimed.destination_version,
    claimed.attempt_count
  from claimed
  join public.alert_events event on event.id = claimed.alert_event_id
  join public.trusted_contacts contact on contact.id = event.trusted_contact_id;
$$;


create or replace function public.finish_alert_delivery(
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
  where id = p_delivery_id and lease_owner = p_worker_id and lease_expires_at>now() and status='queued'
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
  where id = p_delivery_id and lease_owner = p_worker_id and lease_expires_at>now() and status='queued';
  return found;
end;
$$;


create or replace function public.claim_contact_verification_deliveries(
  p_worker_id uuid,
  p_limit integer default 1
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
      and delivery.created_at>now()-interval '30 minutes'
      and delivery.attempt_count < delivery.max_attempts
      and delivery.next_attempt_at <= now()
      and (delivery.lease_expires_at is null or delivery.lease_expires_at <= now())
    order by delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit least(greatest(p_limit, 1), 3)
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
    claimed.payload_key_version, claimed.destination_snapshot,
    claimed.destination_version, claimed.attempt_count
  from claimed
  join public.trusted_contacts contact on contact.id = claimed.trusted_contact_id;
$$;


create or replace function public.finish_contact_verification_delivery(
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
  where id = p_delivery_id and lease_owner = p_worker_id and lease_expires_at>now() and status='queued'
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
  where id = p_delivery_id and lease_owner = p_worker_id and lease_expires_at>now() and status='queued';
  return found;
end;
$$;
