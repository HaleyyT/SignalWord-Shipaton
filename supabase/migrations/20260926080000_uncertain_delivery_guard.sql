-- A timed-out provider attempt may have been accepted. Quarantine expired leases
-- before another worker can claim them; explicit rejected retries clear the lease.
create or replace function public.recover_expired_delivery_leases() returns void language plpgsql security definer set search_path='' as $$
begin
 update public.alert_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (lease_owner is not null or attempt_count>=max_attempts or created_at<now()-interval '23 hours');
 update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (lease_owner is not null or attempt_count>=max_attempts or created_at<now()-interval '30 minutes');
end $$;

create or replace function public.claim_alert_deliveries_without_name(
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
      and delivery.lease_owner is null and delivery.lease_expires_at is null
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
      and delivery.lease_owner is null and delivery.lease_expires_at is null
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
