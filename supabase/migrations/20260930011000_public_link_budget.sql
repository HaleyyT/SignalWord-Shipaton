-- Separate read and acknowledgement budgets: polling cannot exhaust acknowledgement.
create function public.consume_viewer_budget(p_token_hash bytea,p_action text) returns boolean
language plpgsql security definer set search_path='' as $$
declare subject bytea; window_start timestamptz:=date_trunc('minute',statement_timestamp()); count integer;
begin
 -- Unknown capabilities never allocate persistent counters.
 if not exists(select 1 from public.viewer_tokens where token_hash=p_token_hash and revoked_at is null and expires_at>now()) then return true; end if;
 subject:=extensions.digest(p_token_hash||convert_to(p_action,'UTF8'),'sha256');
 insert into public.rate_limit_buckets(scope,subject_hash,window_started_at,request_count,expires_at)
 values('viewer_token',subject,window_start,1,window_start+interval '2 minutes')
 on conflict(scope,subject_hash,window_started_at) do update
 set request_count=public.rate_limit_buckets.request_count+1
 returning request_count into count;
 return count<=case when p_action='read' then 120 else 20 end;
end $$;
revoke all on function public.consume_viewer_budget(bytea,text) from public,anon,authenticated;
alter function public.get_public_event(bytea) rename to get_public_event_before_budget;
revoke all on function public.get_public_event_before_budget(bytea) from public,anon,authenticated;
create function public.get_public_event(p_token_hash bytea) returns table(projection jsonb)
language plpgsql security definer set search_path='' as $$
begin
 if not public.consume_viewer_budget(p_token_hash,'read') then raise exception 'RATE_LIMITED'; end if;
 return query select * from public.get_public_event_before_budget(p_token_hash);
end $$;
revoke all on function public.get_public_event(bytea) from public;
grant execute on function public.get_public_event(bytea) to anon,authenticated;
alter function public.acknowledge_public_event(bytea) rename to acknowledge_public_event_before_budget;
revoke all on function public.acknowledge_public_event_before_budget(bytea) from public,anon,authenticated;
create function public.acknowledge_public_event(p_token_hash bytea) returns boolean
language plpgsql security definer set search_path='' as $$
begin
 if not public.consume_viewer_budget(p_token_hash,'ack') then raise exception 'RATE_LIMITED'; end if;
 return public.acknowledge_public_event_before_budget(p_token_hash);
end $$;
revoke all on function public.acknowledge_public_event(bytea) from public;
grant execute on function public.acknowledge_public_event(bytea) to anon,authenticated;
