-- Track only request IDs and timestamps, never Vault secrets or request bodies.
create table public.dispatch_requests (
  request_id bigint primary key,
  requested_at timestamptz not null default now()
);
alter table public.dispatch_requests enable row level security;
revoke all on public.dispatch_requests from public, anon, authenticated;

create or replace function public.wake_signalword_dispatch() returns void
language plpgsql security definer set search_path='' as $$
declare backend text; secret text; request_id bigint;
begin
 select decrypted_secret into backend from vault.decrypted_secrets where name='signalword_backend_url' limit 1;
 select decrypted_secret into secret from vault.decrypted_secrets where name='signalword_dispatch_secret' limit 1;
 if backend is null or secret is null or char_length(secret)<32 then return; end if;
 select net.http_post(url:=rtrim(backend,'/') || '/functions/v1/dispatch-deliveries',
   headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),
   body:='{}'::jsonb,timeout_milliseconds:=30000) into request_id;
 insert into public.dispatch_requests(request_id) values (request_id);
 delete from public.dispatch_requests where requested_at < now()-interval '1 day';
end $$;

alter function public.signalword_operational_health() rename to signalword_operational_health_before_http;
revoke all on function public.signalword_operational_health_before_http() from public, anon, authenticated, service_role;
create function public.signalword_operational_health() returns jsonb
language sql stable security definer set search_path='' as $$
 select public.signalword_operational_health_before_http() || jsonb_build_object(
  'dispatchHTTP', jsonb_build_object(
    'lastCompletedAt', (select r.created from public.dispatch_requests d join net._http_response r on r.id=d.request_id order by d.requested_at desc limit 1),
    'lastStatus', (select r.status_code from public.dispatch_requests d join net._http_response r on r.id=d.request_id order by d.requested_at desc limit 1),
    'timedOut', (select r.timed_out from public.dispatch_requests d join net._http_response r on r.id=d.request_id order by d.requested_at desc limit 1),
    'overdue', (select count(*) from public.dispatch_requests d left join net._http_response r on r.id=d.request_id
      where r.id is null and d.requested_at < now()-interval '60 seconds' and d.requested_at > now()-interval '5 minutes')
  ),
  'abuse', jsonb_build_object(
    'signupsLastHour', (select count(*) from auth.users where created_at > now()-interval '1 hour'),
    'invitationsLastHour', (select count(*) from public.contact_verification_deliveries where created_at > now()-interval '1 hour')
  )
 );
$$;
revoke all on function public.signalword_operational_health() from public, anon, authenticated;
grant execute on function public.signalword_operational_health() to service_role;
