-- Provision signalword_backend_url and signalword_dispatch_secret in Vault.
-- No secret is embedded in a cron command, migration, or public configuration.
create extension if not exists pg_net with schema extensions;
create function public.wake_signalword_dispatch() returns void language plpgsql security definer set search_path='' as $$
declare backend text; secret text;
begin
 select decrypted_secret into backend from vault.decrypted_secrets where name='signalword_backend_url' limit 1;
 select decrypted_secret into secret from vault.decrypted_secrets where name='signalword_dispatch_secret' limit 1;
 if backend is null or secret is null or char_length(secret)<32 then return; end if;
 perform net.http_post(url:=rtrim(backend,'/') || '/functions/v1/dispatch-deliveries',
   headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||secret),body:='{}'::jsonb,timeout_milliseconds:=30000);
end $$;
revoke all on function public.wake_signalword_dispatch() from public;
select cron.schedule('signalword-dispatch-sweep','* * * * *','select public.wake_signalword_dispatch()');
