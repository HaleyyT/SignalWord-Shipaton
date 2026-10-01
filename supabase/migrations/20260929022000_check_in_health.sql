alter function public.signalword_operational_health() rename to signalword_operational_health_before_timers;
revoke all on function public.signalword_operational_health_before_timers() from public,anon,authenticated,service_role;
create function public.signalword_operational_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select public.signalword_operational_health_before_timers() || jsonb_build_object('checkIns',jsonb_build_object(
  'overdue',(select count(*) from public.check_in_timers where state='active' and grace_ends_at<now()-interval '2 minutes'),
  'failed',(select count(*) from public.check_in_timers where state='failed' and updated_at>now()-interval '1 hour'),
  'schedules',(select jsonb_agg(jsonb_build_object('name',expected.name,'active',coalesce(job.active,false),
   'lastSuccessAt',(select max(r.end_time) from cron.job_run_details r where r.jobid=job.jobid and r.status='succeeded')))
   from (values ('signalword-check-in-expiry'),('signalword-check-in-retention')) expected(name) left join cron.job job on job.jobname=expected.name)
 ));
$$;
revoke all on function public.signalword_operational_health() from public,anon,authenticated;
grant execute on function public.signalword_operational_health() to service_role;
