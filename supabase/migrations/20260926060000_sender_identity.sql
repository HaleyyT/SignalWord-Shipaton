-- New workers receive the sender label; old workers ignore the additive field.
alter function public.claim_alert_deliveries(uuid,integer) rename to claim_alert_deliveries_without_name;
revoke all on function public.claim_alert_deliveries_without_name(uuid,integer) from service_role;
create function public.claim_alert_deliveries(p_worker_id uuid,p_limit integer default 1)
returns table(delivery_id uuid,event_id uuid,kind text,message_type text,provider text,
 provider_idempotency_key text,payload_ciphertext text,payload_key_version smallint,
 destination_ciphertext text,destination_key_version smallint,attempt_count integer,sender_name text)
language sql security definer set search_path='' as $$
 select d.*,p.display_name from public.claim_alert_deliveries_without_name(p_worker_id,p_limit) d
 join public.alert_events e on e.id=d.event_id join public.profiles p on p.id=e.user_id;
$$;
revoke all on function public.claim_alert_deliveries(uuid,integer) from public;
grant execute on function public.claim_alert_deliveries(uuid,integer) to service_role;
