-- Additive lifecycle interfaces: old clients retain their original contracts.
alter table public.alert_events add column acknowledged_at timestamptz;
alter table public.alert_events add column client_triggered_at timestamptz;

create function public.signalword_profile(p_user_id uuid, p_display_name text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode = '42501'; end if;
  if p_display_name is not null then
    if char_length(btrim(p_display_name)) not between 1 and 80 then raise exception 'INVALID_PROFILE'; end if;
    update public.profiles set display_name = btrim(p_display_name) where id = p_user_id;
  end if;
  return (select jsonb_build_object('displayName', display_name) from public.profiles where id = p_user_id);
end $$;
revoke all on function public.signalword_profile(uuid,text) from public;
grant execute on function public.signalword_profile(uuid,text) to authenticated;

create function public.alert_details(p_user_id uuid, p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'eventId', e.id, 'kind', e.kind, 'state', case when e.expires_at <= now() then 'expired' else e.state end,
    'triggeredAt', e.triggered_at, 'clientTriggeredAt', e.client_triggered_at,
    'resolvedAt', e.resolved_at, 'acknowledgedAt', e.acknowledged_at,
    'delivery', coalesce((select d.status from public.alert_deliveries d where d.alert_event_id=e.id and d.message_type='initial' limit 1),'queued'),
    'resolutionDelivery', (select d.status from public.alert_deliveries d where d.alert_event_id=e.id and d.message_type='resolved' limit 1)))
  from public.alert_events e where e.id=p_event_id and e.user_id=p_user_id and auth.uid()=p_user_id;
$$;
revoke all on function public.alert_details(uuid,uuid) from public;
grant execute on function public.alert_details(uuid,uuid) to authenticated;

create function public.recover_alerts(p_user_id uuid, p_idempotency_key uuid default null)
returns jsonb language sql stable security definer set search_path = '' as $$
 select coalesce(jsonb_agg(public.alert_details(p_user_id,e.id) order by e.triggered_at desc), '[]'::jsonb)
 from (select * from public.alert_events where user_id=p_user_id and auth.uid()=p_user_id
   and ((p_idempotency_key is not null and idempotency_key=p_idempotency_key)
     or (p_idempotency_key is null and expires_at>now() and state in ('pending','active')))
   order by triggered_at desc limit 100) e;
$$;
revoke all on function public.recover_alerts(uuid,uuid) from public;
grant execute on function public.recover_alerts(uuid,uuid) to authenticated;

-- Holding the event lock serializes acknowledgement with resolution; no GET side effect.
create function public.acknowledge_public_event(p_token_hash bytea)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_id uuid;
begin
 select e.id into v_id from public.viewer_tokens t join public.alert_events e on e.id=t.alert_event_id
 where t.token_hash=p_token_hash and t.revoked_at is null and t.expires_at>now() and e.expires_at>now()
 and e.state in ('active','resolved') for update of e;
 if v_id is null then return false; end if;
 update public.alert_events set acknowledged_at=coalesce(acknowledged_at,now()) where id=v_id;
 return true;
end $$;
revoke all on function public.acknowledge_public_event(bytea) from public;
grant execute on function public.acknowledge_public_event(bytea) to anon, authenticated;

-- Extend projection without changing the old allowlist's fields.
alter function public.get_public_event(bytea) rename to get_public_event_before_ack;
revoke all on function public.get_public_event_before_ack(bytea) from anon, authenticated;
create function public.get_public_event(p_token_hash bytea)
returns table(projection jsonb) language sql stable security definer set search_path = '' as $$
 select old.projection || jsonb_strip_nulls(jsonb_build_object('acknowledgedAt',e.acknowledged_at,
   'serverNow',now(),'clientTriggeredAt',e.client_triggered_at))
 from public.get_public_event_before_ack(p_token_hash) old
 join public.viewer_tokens t on t.token_hash=p_token_hash
 join public.alert_events e on e.id=t.alert_event_id;
$$;
revoke all on function public.get_public_event(bytea) from public;
grant execute on function public.get_public_event(bytea) to anon, authenticated;

-- Map every command key, including cooldown aliases, to its canonical event.
create table public.alert_command_aliases (
 user_id uuid not null references public.profiles(id) on delete cascade,
 command_key uuid not null, event_id uuid not null references public.alert_events(id) on delete cascade,
 primary key(user_id,command_key)
);
alter table public.alert_command_aliases enable row level security;
revoke all on public.alert_command_aliases from anon, authenticated;
alter function public.create_or_reuse_alert(uuid,uuid,text,text,text,text,text,integer,jsonb) rename to create_or_reuse_alert_legacy;
revoke all on function public.create_or_reuse_alert_legacy(uuid,uuid,text,text,text,text,text,integer,jsonb) from authenticated;
create function public.create_or_reuse_alert(
 p_user_id uuid,p_idempotency_key uuid,p_kind text,p_trigger_method text,p_viewer_token text,
 p_delivery_provider text,p_delivery_payload_ciphertext text,p_delivery_payload_key_version integer,
 p_location jsonb default null,p_client_triggered_at timestamptz default null
) returns table(event_id uuid,event_state text,delivery_status text,server_triggered_at timestamptz,reused boolean)
language plpgsql security definer set search_path='' as $$
declare r record; v_alias uuid;
begin
 if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
 select a.event_id into v_alias from public.alert_command_aliases a where a.user_id=p_user_id and a.command_key=p_idempotency_key;
 if v_alias is not null then
  return query select e.id,e.state,coalesce((select d.status from public.alert_deliveries d where d.alert_event_id=e.id and d.message_type='initial' limit 1),'queued'),e.triggered_at,true
   from public.alert_events e where e.id=v_alias; return;
 end if;
 select * into r from public.create_or_reuse_alert_legacy(p_user_id,p_idempotency_key,p_kind,p_trigger_method,p_viewer_token,p_delivery_provider,p_delivery_payload_ciphertext,p_delivery_payload_key_version,p_location);
 insert into public.alert_command_aliases values(p_user_id,p_idempotency_key,r.event_id) on conflict do nothing;
 if not r.reused then update public.alert_events set client_triggered_at=p_client_triggered_at where id=r.event_id; end if;
 return query select r.event_id,r.event_state,r.delivery_status,r.server_triggered_at,r.reused;
end $$;
revoke all on function public.create_or_reuse_alert(uuid,uuid,text,text,text,text,text,integer,jsonb,timestamptz) from public;
grant execute on function public.create_or_reuse_alert(uuid,uuid,text,text,text,text,text,integer,jsonb,timestamptz) to authenticated;
create or replace function public.recover_alerts(p_user_id uuid,p_idempotency_key uuid default null)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(public.alert_details(p_user_id,e.id) order by e.triggered_at desc),'[]'::jsonb)
 from (select * from public.alert_events e where e.user_id=p_user_id and auth.uid()=p_user_id
 and ((p_idempotency_key is not null and (e.idempotency_key=p_idempotency_key or exists(
  select 1 from public.alert_command_aliases a where a.user_id=p_user_id and a.command_key=p_idempotency_key and a.event_id=e.id)))
 or (p_idempotency_key is null and e.expires_at>now() and e.state in ('pending','active')))
 order by e.triggered_at desc limit 100) e;
$$;
