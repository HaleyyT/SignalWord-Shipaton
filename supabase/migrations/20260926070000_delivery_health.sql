-- Operator-only aggregate metrics. No event IDs, recipients or capabilities.
create function public.signalword_delivery_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object(
 'queued',count(*) filter(where status='queued'),
 'failed',count(*) filter(where status='failed'),
 'unknown',count(*) filter(where last_error_code='OUTCOME_UNKNOWN'),
 'oldestQueuedSeconds',coalesce(extract(epoch from now()-min(created_at) filter(where status='queued')),0),
 'expiredLeases',count(*) filter(where status='queued' and lease_expires_at<=now()))
 from public.alert_deliveries;
$$;
revoke all on function public.signalword_delivery_health() from public;
grant execute on function public.signalword_delivery_health() to service_role;
