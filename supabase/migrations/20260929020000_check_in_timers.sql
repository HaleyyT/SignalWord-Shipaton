-- Server-owned timers. Mobile notifications are supplementary and never expire a timer.
alter table public.alert_events add column cause text not null default 'user_triggered'
 check(cause in ('user_triggered','missed_check_in'));
alter table public.alert_events add column check_in_deadline timestamptz;
create table public.check_in_timers (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references public.profiles(id) on delete cascade,
 state text not null default 'active' check(state in ('active','checked_in','cancelled','escalated','failed')),
 deadline timestamptz not null,
 grace_ends_at timestamptz not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 incident_id uuid references public.alert_events(id) on delete set null,
 failure_code text,
 provider text not null check(provider in ('fake','resend')),
 recipient_payloads jsonb not null,
 check(grace_ends_at=deadline+interval '1 minute')
);
create unique index check_in_one_active on public.check_in_timers(user_id) where state='active';
create index check_in_due on public.check_in_timers(grace_ends_at) where state='active';
create table public.check_in_operations (
 user_id uuid not null references public.profiles(id) on delete cascade,
 command_id uuid not null,
 timer_id uuid references public.check_in_timers(id) on delete set null,
 action text not null,
 minutes integer,
 created_at timestamptz not null default now(),
 primary key(user_id,command_id)
);
alter table public.check_in_timers enable row level security;
alter table public.check_in_operations enable row level security;
revoke all on public.check_in_timers,public.check_in_operations from anon,authenticated;

create function public.check_in_projection(p_user_id uuid,p_timer_id uuid default null)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object('timerId',id,'state',state,'deadline',deadline,'graceEndsAt',grace_ends_at,
  'serverNow',now(),'incidentId',incident_id,'failureCode',failure_code,
  'incidentState',(select case when e.expires_at<=now() then 'expired' else e.state end from public.alert_events e where e.id=incident_id)))
 from public.check_in_timers where user_id=p_user_id and auth.uid()=p_user_id
 and (p_timer_id is null or id=p_timer_id) order by created_at desc,id desc limit 1;
$$;
revoke all on function public.check_in_projection(uuid,uuid) from public;
grant execute on function public.check_in_projection(uuid,uuid) to authenticated;

-- The caller already holds the user advisory lock and timer row lock.
-- Both the API and sweeper use this same transition, including late check-ins.
create function public.expire_check_in(p_timer_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare t public.check_in_timers%rowtype; e uuid; c record; primary_id uuid; policy text; payload jsonb; n integer:=0; due timestamptz;
begin
 select * into t from public.check_in_timers where id=p_timer_id for update;
 if not found or t.state<>'active' or t.grace_ends_at>clock_timestamp() then return; end if;
 select id into e from public.alert_events where user_id=t.user_id and kind='real' and state in ('pending','active') and expires_at>now() order by triggered_at desc limit 1;
 if e is null then
  perform pg_advisory_xact_lock(hashtextextended(t.user_id::text,1));
  perform 1 from public.trusted_contacts where user_id=t.user_id order by id for update;
  select id into primary_id from public.trusted_contacts where user_id=t.user_id and is_primary and status='confirmed';
  if primary_id is null then
   update public.check_in_timers set state='failed',failure_code='CONTACT_NOT_CONFIRMED',updated_at=now() where id=t.id;
   return;
  end if;
  select routing_policy into policy from public.profiles where id=t.user_id;
  insert into public.alert_events(user_id,trusted_contact_id,idempotency_key,kind,state,trigger_method,cause,check_in_deadline,client_triggered_at,routing_policy)
   values(t.user_id,primary_id,t.id,'real','active','manual','missed_check_in',t.deadline,t.deadline,policy) returning id into e;
  for c in select * from public.trusted_contacts where user_id=t.user_id and status='confirmed' order by is_primary desc,created_at,id loop
   payload:=t.recipient_payloads->n; n:=n+1;
   due:=now()+case when policy='primary_then_others' and not c.is_primary then interval '2 minutes' else interval '0' end;
   insert into public.viewer_tokens(alert_event_id,trusted_contact_id,token_hash,expires_at)
    select id,c.id,decode(payload->>'hash','hex'),expires_at from public.alert_events where id=e;
   insert into public.alert_deliveries(alert_event_id,trusted_contact_id,provider,provider_idempotency_key,message_type,payload_ciphertext,payload_key_version,next_attempt_at)
    values(e,c.id,t.provider,'alert/'||e::text||'/'||c.id::text||'/initial','initial',payload->>'ciphertext',(payload->>'keyVersion')::smallint,due);
  end loop;
 end if;
 -- Existing REAL incidents gain a timer association, not another notification batch.
 update public.check_in_timers set state='escalated',incident_id=e,updated_at=now() where id=t.id;
end $$;
revoke all on function public.expire_check_in(uuid) from public,anon,authenticated,service_role;

create function public.change_check_in(p_user_id uuid,p_command_id uuid,p_action text,p_timer_id uuid default null,
 p_minutes integer default null,p_provider text default null,p_payloads jsonb default null)
returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.check_in_timers%rowtype; op public.check_in_operations%rowtype; payload jsonb; accepted_at timestamptz;
begin
 if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
 accepted_at:=clock_timestamp();
 select * into op from public.check_in_operations where user_id=p_user_id and command_id=p_command_id;
 if found then
  if op.timer_id is null then raise exception 'IDEMPOTENCY_EXPIRED'; end if;
  if op.action is distinct from p_action or op.minutes is distinct from p_minutes or (p_timer_id is not null and op.timer_id<>p_timer_id) then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
  return public.check_in_projection(p_user_id,op.timer_id);
 end if;
 if (select count(*) from public.check_in_operations where user_id=p_user_id and created_at>now()-interval '1 hour')>=60 then raise exception 'RATE_LIMITED'; end if;
 if p_action not in ('start','extend','check_in','cancel') then raise exception 'INVALID_TIMER_ACTION'; end if;
 if p_action in ('start','extend') and (p_minutes is null or p_minutes not in (15,30,60)) then raise exception 'INVALID_TIMER_DURATION'; end if;
 if p_action='start' then
  if exists(select 1 from public.check_in_timers where user_id=p_user_id and state='active') then raise exception 'TIMER_ALREADY_ACTIVE'; end if;
  if not exists(select 1 from public.trusted_contacts where user_id=p_user_id and is_primary and status='confirmed') then raise exception 'CONTACT_NOT_CONFIRMED'; end if;
  if p_provider is null or p_provider not in ('fake','resend') or jsonb_typeof(p_payloads) is distinct from 'array' or jsonb_array_length(p_payloads)<>3 then raise exception 'INVALID_TIMER_CONFIGURATION'; end if;
  if (select count(distinct value->>'hash') from jsonb_array_elements(p_payloads))<>3 then raise exception 'INVALID_TIMER_CONFIGURATION'; end if;
  for payload in select value from jsonb_array_elements(p_payloads) loop
   if coalesce(payload->>'hash','') !~ '^[a-f0-9]{64}$' or coalesce(length(payload->>'ciphertext'),0)<24 or
    coalesce((payload->>'keyVersion')::integer,0) not between 1 and 32767 then raise exception 'INVALID_TIMER_CONFIGURATION'; end if;
  end loop;
  insert into public.check_in_timers(user_id,deadline,grace_ends_at,provider,recipient_payloads)
   values(p_user_id,accepted_at+make_interval(mins=>p_minutes),accepted_at+make_interval(mins=>p_minutes)+interval '1 minute',p_provider,p_payloads) returning * into t;
 else
  select * into t from public.check_in_timers where id=p_timer_id and user_id=p_user_id for update;
  if not found then raise exception 'TIMER_NOT_FOUND'; end if;
  -- After the grace deadline, a delayed API request cannot silently undo expiry.
  perform public.expire_check_in(t.id);
  select * into t from public.check_in_timers where id=t.id;
  if t.state='active' then
   if p_action='extend' then
    update public.check_in_timers set deadline=greatest(deadline,accepted_at)+make_interval(mins=>p_minutes),grace_ends_at=greatest(deadline,accepted_at)+make_interval(mins=>p_minutes)+interval '1 minute',updated_at=now() where id=t.id;
   else
    update public.check_in_timers set state=case when p_action='check_in' then 'checked_in' else 'cancelled' end,updated_at=now() where id=t.id;
   end if;
  end if;
 end if;
 insert into public.check_in_operations(user_id,command_id,timer_id,action,minutes) values(p_user_id,p_command_id,t.id,p_action,p_minutes);
 return public.check_in_projection(p_user_id,t.id);
end $$;
revoke all on function public.change_check_in(uuid,uuid,text,uuid,integer,text,jsonb) from public;
grant execute on function public.change_check_in(uuid,uuid,text,uuid,integer,text,jsonb) to authenticated;

create function public.sweep_check_ins() returns integer language plpgsql security definer set search_path='' as $$
declare candidate record; count_expired integer:=0;
begin
 for candidate in select id,user_id from public.check_in_timers where state='active' and grace_ends_at<=now() order by grace_ends_at limit 100 loop
  -- Same lock order as foreground changes and alert creation, never timer then user.
  if pg_try_advisory_xact_lock(hashtextextended(candidate.user_id::text,0)) then
   perform public.expire_check_in(candidate.id);
   count_expired:=count_expired+1;
  end if;
 end loop;
 if count_expired>0 then
  -- pg_net dispatches after commit. Failure must not roll back durable incidents;
  -- the independent periodic delivery sweep remains the recovery path.
  begin perform public.wake_signalword_dispatch(); exception when others then null; end;
 end if;
 return count_expired;
end $$;
revoke all on function public.sweep_check_ins() from public,anon,authenticated;
grant execute on function public.sweep_check_ins() to service_role;
select cron.schedule('signalword-check-in-expiry','* * * * *','select public.sweep_check_ins();');
