-- Correlation uses only a hash of the original provider idempotency key. Receipt
-- authentication belongs to the webhook handler; this RPC is service-role only.
create index alert_delivery_correlation on public.alert_deliveries
  ((encode(extensions.digest(provider_idempotency_key, 'sha256'), 'hex')))
  where provider = 'resend';
create index contact_delivery_correlation on public.contact_verification_deliveries
  ((encode(extensions.digest(provider_idempotency_key, 'sha256'), 'hex')))
  where provider = 'resend';

create function public.reconcile_resend_webhook(
  p_provider_event_id text,
  p_provider_message_id text,
  p_event_type text,
  p_correlation text default null
) returns boolean language plpgsql security definer set search_path = '' as $$
declare inserted boolean;
begin
  if p_provider_event_id is null or p_provider_message_id is null or p_event_type is null then
    raise exception using errcode = '22023', message = 'INVALID_WEBHOOK_EVENT';
  end if;
  if p_correlation is not null and p_correlation !~ '^[a-f0-9]{64}$' then
    raise exception using errcode = '22023', message = 'INVALID_CORRELATION';
  end if;

  -- Store the immutable receipt first. Existing triggers apply terminal precedence
  -- when the missing provider ID is attached, including callbacks preceding finish.
  inserted := public.apply_resend_webhook(p_provider_event_id, p_provider_message_id, p_event_type);
  if not exists (
    select 1 from public.delivery_webhook_receipts
    where provider = 'resend' and provider_event_id = p_provider_event_id
      and provider_message_id = p_provider_message_id and event_type = p_event_type
  ) then
    raise exception using errcode = '22023', message = 'CONFLICTING_WEBHOOK_RECEIPT';
  end if;
  if p_correlation is not null then
    update public.alert_deliveries
    set provider_message_id = p_provider_message_id,
        status = 'sent', last_error_code = null, completed_at = null,
        lease_owner = null, lease_expires_at = null, updated_at = now()
    where provider = 'resend' and provider_message_id is null
      and attempt_count > 0
      and (status = 'queued' or (status = 'failed' and last_error_code = 'OUTCOME_UNKNOWN'))
      and encode(extensions.digest(provider_idempotency_key, 'sha256'), 'hex') = p_correlation;

    update public.contact_verification_deliveries
    set provider_message_id = p_provider_message_id,
        status = 'sent', last_error_code = null, completed_at = null,
        lease_owner = null, lease_expires_at = null, updated_at = now()
    where provider = 'resend' and provider_message_id is null
      and attempt_count > 0
      and (status = 'queued' or (status = 'failed' and last_error_code = 'OUTCOME_UNKNOWN'))
      and encode(extensions.digest(provider_idempotency_key, 'sha256'), 'hex') = p_correlation;
  end if;
  -- No callback or unmatched older send remains unknown. Absence of evidence is
  -- never permission to requeue, even after the provider deduplication window.
  return inserted;
end $$;
revoke all on function public.reconcile_resend_webhook(text,text,text,text) from public;
grant execute on function public.reconcile_resend_webhook(text,text,text,text) to service_role;
