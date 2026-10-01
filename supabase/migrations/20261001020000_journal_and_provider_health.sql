-- Operational projections contain counts and ages only, never recipient data.
alter function public.signalword_operational_health() rename to signalword_operational_health_before_journal;
revoke all on function public.signalword_operational_health_before_journal() from public,anon,authenticated,service_role;
create function public.signalword_operational_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select public.signalword_operational_health_before_journal() || jsonb_build_object(
  'journal',jsonb_build_object(
   'pending',(select count(*) from public.safety_journal_outbox where durable_at is null),
   'oldestPendingSeconds',(select coalesce(greatest(0,extract(epoch from now()-min(created_at))),0) from public.safety_journal_outbox where durable_at is null)),
  'provider',jsonb_build_object(
   'callbackOverdue',(select count(*) from (
     select provider,provider_message_id,last_attempt_at from public.alert_deliveries where status='sent'
     union all select provider,provider_message_id,last_attempt_at from public.contact_verification_deliveries where status='sent'
    ) d where d.provider='resend' and d.last_attempt_at<now()-interval '2 minutes'
      and not exists(select 1 from public.delivery_webhook_receipts r where r.provider=d.provider and r.provider_message_id=d.provider_message_id)),
   'deliveryReportOverdue',(select count(*) from (
     select provider,last_attempt_at from public.alert_deliveries where status='sent'
     union all select provider,last_attempt_at from public.contact_verification_deliveries where status='sent'
    ) d where d.provider='resend' and d.last_attempt_at<now()-interval '15 minutes')));
$$;
revoke all on function public.signalword_operational_health() from public,anon,authenticated;
grant execute on function public.signalword_operational_health() to service_role;
