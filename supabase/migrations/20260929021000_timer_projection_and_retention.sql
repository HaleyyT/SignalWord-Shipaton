create function public.recover_check_in(p_user_id uuid,p_command_id uuid default null)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when p_command_id is null then public.check_in_projection(p_user_id)
 else (select public.check_in_projection(p_user_id,timer_id) from public.check_in_operations where user_id=p_user_id and command_id=p_command_id and auth.uid()=p_user_id) end;
$$;
revoke all on function public.recover_check_in(uuid,uuid) from public;
grant execute on function public.recover_check_in(uuid,uuid) to authenticated;
create function public.purge_check_ins() returns void language plpgsql security definer set search_path='' as $$
begin
 update public.check_in_timers set recipient_payloads='[]'::jsonb where state<>'active' and recipient_payloads<>'[]'::jsonb;
 delete from public.check_in_timers where state<>'active' and updated_at<now()-interval '24 hours';
end $$;
revoke all on function public.purge_check_ins() from public,anon,authenticated;
grant execute on function public.purge_check_ins() to service_role;
select cron.schedule('signalword-check-in-retention','23 * * * *','select public.purge_check_ins();');

alter function public.claim_alert_deliveries(uuid,integer) rename to claim_alert_deliveries_before_cause;
revoke all on function public.claim_alert_deliveries_before_cause(uuid,integer) from service_role;
create function public.claim_alert_deliveries(p_worker_id uuid,p_limit integer default 1)
returns table(delivery_id uuid,event_id uuid,kind text,message_type text,provider text,
 provider_idempotency_key text,payload_ciphertext text,payload_key_version smallint,
 destination_ciphertext text,destination_key_version smallint,attempt_count integer,sender_name text,cause text)
language sql security definer set search_path='' as $$
 select d.*,e.cause from public.claim_alert_deliveries_before_cause(p_worker_id,p_limit) d join public.alert_events e on e.id=d.event_id;
$$;
revoke all on function public.claim_alert_deliveries(uuid,integer) from public;
grant execute on function public.claim_alert_deliveries(uuid,integer) to service_role;

alter function public.get_public_event(bytea) rename to get_public_event_before_cause;
revoke all on function public.get_public_event_before_cause(bytea) from anon,authenticated;
create function public.get_public_event(p_token_hash bytea)
returns table(projection jsonb) language sql stable security definer set search_path='' as $$
 select old.projection || jsonb_strip_nulls(jsonb_build_object('cause',e.cause,'checkInDeadline',e.check_in_deadline))
 from public.get_public_event_before_cause(p_token_hash) old join public.viewer_tokens t on t.token_hash=p_token_hash
 join public.alert_events e on e.id=t.alert_event_id;
$$;
revoke all on function public.get_public_event(bytea) from public;
grant execute on function public.get_public_event(bytea) to anon,authenticated;
