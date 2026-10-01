-- Deliberate escalation delays are not an overdue delivery queue.
create or replace function public.signalword_delivery_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('queued',count(*) filter(where status='queued'),
 'failed',count(*) filter(where status='failed'),'unknown',count(*) filter(where last_error_code='OUTCOME_UNKNOWN'),
 'oldestQueuedSeconds',coalesce(extract(epoch from now()-min(next_attempt_at) filter(where status='queued' and next_attempt_at<=now())),0),
 'expiredLeases',count(*) filter(where status='queued' and lease_expires_at<=now())) from public.alert_deliveries;
$$;
