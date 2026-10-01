-- Aggregate-only operational evidence. Secrets, identities, tokens, and locations
-- never leave this service-role RPC. A successful cron SQL call is not delivery.
create function public.signalword_operational_health() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'delivery', public.signalword_delivery_health(),
    'contactDelivery', (select jsonb_build_object(
      'queued', count(*) filter (where status = 'queued'),
      'unknown', count(*) filter (where last_error_code = 'OUTCOME_UNKNOWN'),
      'oldestQueuedSeconds', coalesce(extract(epoch from now() - min(created_at) filter (where status = 'queued')), 0),
      'expiredLeases', count(*) filter (where status = 'queued' and lease_expires_at <= now())
    ) from public.contact_verification_deliveries),
    'dispatchConfigured', (
      exists(select 1 from vault.decrypted_secrets where name = 'signalword_backend_url' and decrypted_secret ~ '^https://[^/]+$')
      and exists(select 1 from vault.decrypted_secrets where name = 'signalword_dispatch_secret' and length(decrypted_secret) >= 32)
    ),
    'schedules', (select jsonb_agg(jsonb_build_object(
      'name', expected.name,
      'active', coalesce(job.active, false),
      'lastSuccessAt', (select max(run.end_time) from cron.job_run_details run
        where run.jobid = job.jobid and run.status = 'succeeded'),
      'maximumAgeSeconds', expected.maximum_age
    )) from (values
      ('signalword-dispatch-sweep', 180),
      ('signalword-delivery-lease-recovery', 180),
      ('signalword-hourly-retention', 4500)
    ) expected(name, maximum_age) left join cron.job job on job.jobname = expected.name)
  );
$$;
revoke all on function public.signalword_operational_health() from public;
grant execute on function public.signalword_operational_health() to service_role;
