-- Recipient-scoped routing. Existing APIs keep their single-primary semantics.
-- All schema changes are additive except widening the one-contact uniqueness
-- constraint; a lock-protected trigger enforces the new three-contact bound.
alter table public.trusted_contacts drop constraint one_contact_per_user;
alter table public.trusted_contacts add column is_primary boolean not null default false;
update public.trusted_contacts set is_primary=true;
create unique index trusted_contacts_one_primary on public.trusted_contacts(user_id) where is_primary;
alter table public.profiles add column routing_policy text not null default 'everyone'
 check (routing_policy in ('everyone','primary_then_others'));
alter table public.alert_events add column routing_policy text not null default 'everyone'
 check (routing_policy in ('everyone','primary_then_others'));
alter table public.viewer_tokens add column trusted_contact_id uuid references public.trusted_contacts(id) on delete cascade;
alter table public.viewer_tokens add column acknowledged_at timestamptz;
alter table public.alert_deliveries add column scheduled_at timestamptz not null default now();
update public.alert_deliveries set scheduled_at=created_at;
alter table public.alert_deliveries add column trusted_contact_id uuid references public.trusted_contacts(id) on delete cascade;
update public.viewer_tokens t set trusted_contact_id=e.trusted_contact_id, acknowledged_at=e.acknowledged_at
 from public.alert_events e where e.id=t.alert_event_id;
update public.alert_deliveries d set trusted_contact_id=e.trusted_contact_id
 from public.alert_events e where e.id=d.alert_event_id;
alter table public.alert_deliveries drop constraint alert_deliveries_event_message_provider_key;
create unique index alert_deliveries_recipient_message_provider on public.alert_deliveries(alert_event_id,trusted_contact_id,message_type,provider);

create function public.enforce_contact_capacity() returns trigger language plpgsql security definer set search_path='' as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.user_id::text,1));
 if (select count(*) from public.trusted_contacts where user_id=new.user_id)>=3 then
  raise exception 'CONTACT_LIMIT' using errcode='23514';
 end if;
 if not exists(select 1 from public.trusted_contacts where user_id=new.user_id) then new.is_primary=true; end if;
 return new;
end $$;
revoke all on function public.enforce_contact_capacity() from public;
create trigger enforce_contact_capacity before insert on public.trusted_contacts for each row execute function public.enforce_contact_capacity();

create or replace function public.snapshot_delivery_destination() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if TG_TABLE_NAME='alert_deliveries' then
  new.scheduled_at := new.next_attempt_at;
  new.trusted_contact_id := coalesce(new.trusted_contact_id,(select trusted_contact_id from public.alert_events where id=new.alert_event_id));
  if not exists(select 1 from public.alert_events e join public.trusted_contacts c on c.user_id=e.user_id
    where e.id=new.alert_event_id and c.id=new.trusted_contact_id) then raise exception 'RECIPIENT_OWNER_MISMATCH'; end if;
 end if;
 select destination_ciphertext,destination_key_version into new.destination_snapshot,new.destination_version
 from public.trusted_contacts where id=new.trusted_contact_id;
 return new;
end $$;

create function public.assign_legacy_viewer_recipient() returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.trusted_contact_id := coalesce(new.trusted_contact_id,(select trusted_contact_id from public.alert_events where id=new.alert_event_id));
 if not exists(select 1 from public.alert_events e join public.trusted_contacts c on c.user_id=e.user_id
   where e.id=new.alert_event_id and c.id=new.trusted_contact_id) then raise exception 'RECIPIENT_OWNER_MISMATCH'; end if;
 return new;
end $$;
revoke all on function public.assign_legacy_viewer_recipient() from public;
create trigger assign_viewer_recipient before insert on public.viewer_tokens for each row execute function public.assign_legacy_viewer_recipient();

-- Only the authenticated Edge API may choose encrypted routing and consent tokens.
-- Client callers must not choose a known confirmation hash and confirm themselves.
-- The API verifies the user JWT before passing that verified user's ID here.
create or replace function public.create_or_replace_contact(
  p_user_id uuid,
  p_name text,
  p_channel text,
  p_destination_ciphertext text,
  p_destination_fingerprint text,
  p_destination_key_version integer,
  p_confirmation_token_hash bytea,
  p_confirmation_payload_ciphertext text,
  p_payload_key_version integer,
  p_delivery_provider text
)
returns table (
  contact_id uuid,
  contact_name text,
  contact_channel text,
  contact_status text,
  confirmation_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact public.trusted_contacts%rowtype;
  v_token_id uuid;
  v_expires_at timestamptz := now() + interval '30 minutes';
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(p_name)) not between 1 and 80
    or p_channel <> 'email'
    or pg_catalog.char_length(p_destination_ciphertext) < 24
    or pg_catalog.char_length(p_destination_fingerprint) <> 64
    or p_destination_key_version not between 1 and 32767
    or pg_catalog.octet_length(p_confirmation_token_hash) <> 32
    or pg_catalog.char_length(p_confirmation_payload_ciphertext) < 24
    or p_payload_key_version not between 1 and 32767
    or p_delivery_provider not in ('fake', 'resend') then
    raise exception using errcode = '22023', message = 'INVALID_CONTACT_CONFIGURATION';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 1));

  select * into v_contact from public.trusted_contacts where user_id = p_user_id and is_primary for update;
  if found then
    update public.viewer_tokens token
      set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where token.trusted_contact_id = v_contact.id
        and token.alert_event_id = event.id;
    update public.trusted_contacts
      set name = pg_catalog.btrim(p_name), channel = p_channel,
        destination_ciphertext = p_destination_ciphertext,
        destination_fingerprint = p_destination_fingerprint,
        destination_key_version = p_destination_key_version::smallint,
        status = 'pending', confirmed_at = null
      where id = v_contact.id
      returning * into v_contact;
  else
    insert into public.trusted_contacts (
      user_id, name, channel, destination_ciphertext, destination_fingerprint,
      destination_key_version, status
    ) values (
      p_user_id, pg_catalog.btrim(p_name), p_channel,
      p_destination_ciphertext, p_destination_fingerprint,
      p_destination_key_version::smallint, 'pending'
    ) returning * into v_contact;
  end if;

  delete from public.contact_confirmation_tokens where trusted_contact_id = v_contact.id;
  insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at)
    values (v_contact.id, p_confirmation_token_hash, v_expires_at)
    returning id into v_token_id;
  insert into public.contact_verification_deliveries (
    trusted_contact_id, provider, provider_idempotency_key,
    payload_ciphertext, payload_key_version
  ) values (
    v_contact.id, p_delivery_provider,
    'contact/' || v_contact.id::text || '/verification/' || v_token_id::text,
    p_confirmation_payload_ciphertext, p_payload_key_version::smallint
  );

  return query select v_contact.id, v_contact.name, v_contact.channel,
    v_contact.status, v_expires_at;
end;
$$;

revoke all on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) from public, anon, authenticated;
grant execute on function public.create_or_replace_contact(uuid, text, text, text, text, integer, bytea, text, integer, text) to service_role;


-- Only the authenticated Edge API may choose encrypted routing and consent tokens.
-- Client callers must not choose a known confirmation hash and confirm themselves.
-- The API verifies the user JWT before passing that verified user's ID here.
create or replace function public.save_network_contact(
  p_contact_id uuid,
  p_user_id uuid,
  p_name text,
  p_channel text,
  p_destination_ciphertext text,
  p_destination_fingerprint text,
  p_destination_key_version integer,
  p_confirmation_token_hash bytea,
  p_confirmation_payload_ciphertext text,
  p_payload_key_version integer,
  p_delivery_provider text
)
returns table (
  contact_id uuid,
  contact_name text,
  contact_channel text,
  contact_status text,
  confirmation_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact public.trusted_contacts%rowtype;
  v_token_id uuid;
  v_expires_at timestamptz := now() + interval '30 minutes';
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  if pg_catalog.char_length(pg_catalog.btrim(p_name)) not between 1 and 80
    or p_channel <> 'email'
    or pg_catalog.char_length(p_destination_ciphertext) < 24
    or pg_catalog.char_length(p_destination_fingerprint) <> 64
    or p_destination_key_version not between 1 and 32767
    or pg_catalog.octet_length(p_confirmation_token_hash) <> 32
    or pg_catalog.char_length(p_confirmation_payload_ciphertext) < 24
    or p_payload_key_version not between 1 and 32767
    or p_delivery_provider not in ('fake', 'resend') then
    raise exception using errcode = '22023', message = 'INVALID_CONTACT_CONFIGURATION';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 1));

  if p_contact_id is null then
    select * into v_contact from public.trusted_contacts where user_id=p_user_id and destination_fingerprint=p_destination_fingerprint;
    if found then
      return query select v_contact.id,v_contact.name,v_contact.channel,v_contact.status,
        (select max(expires_at) from public.contact_confirmation_tokens where trusted_contact_id=v_contact.id);
      return;
    end if;
  end if;
  select * into v_contact from public.trusted_contacts where user_id = p_user_id and id=p_contact_id for update;
  if p_contact_id is not null and not found then raise exception 'CONTACT_NOT_FOUND'; end if;
  if found then
    update public.viewer_tokens token
      set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where token.trusted_contact_id = v_contact.id
        and token.alert_event_id = event.id;
    update public.trusted_contacts
      set name = pg_catalog.btrim(p_name), channel = p_channel,
        destination_ciphertext = p_destination_ciphertext,
        destination_fingerprint = p_destination_fingerprint,
        destination_key_version = p_destination_key_version::smallint,
        status = 'pending', confirmed_at = null
      where id = v_contact.id
      returning * into v_contact;
  else
    insert into public.trusted_contacts (
      user_id, name, channel, destination_ciphertext, destination_fingerprint,
      destination_key_version, status
    ) values (
      p_user_id, pg_catalog.btrim(p_name), p_channel,
      p_destination_ciphertext, p_destination_fingerprint,
      p_destination_key_version::smallint, 'pending'
    ) returning * into v_contact;
  end if;

  delete from public.contact_confirmation_tokens where trusted_contact_id = v_contact.id;
  insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at)
    values (v_contact.id, p_confirmation_token_hash, v_expires_at)
    returning id into v_token_id;
  insert into public.contact_verification_deliveries (
    trusted_contact_id, provider, provider_idempotency_key,
    payload_ciphertext, payload_key_version
  ) values (
    v_contact.id, p_delivery_provider,
    'contact/' || v_contact.id::text || '/verification/' || v_token_id::text,
    p_confirmation_payload_ciphertext, p_payload_key_version::smallint
  );

  return query select v_contact.id, v_contact.name, v_contact.channel,
    v_contact.status, v_expires_at;
end;
$$;


revoke all on function public.save_network_contact(uuid,uuid,text,text,text,text,integer,bytea,text,integer,text) from public,anon,authenticated;
grant execute on function public.save_network_contact(uuid,uuid,text,text,text,text,integer,bytea,text,integer,text) to service_role;

create or replace function public.get_my_contact(p_user_id uuid)
returns table(contact_id uuid,contact_name text,contact_channel text,contact_status text)
language sql stable security definer set search_path='' as $$
 select id,name,channel,status from public.trusted_contacts where user_id=p_user_id and auth.uid()=p_user_id and is_primary;
$$;

create function public.contact_network(p_user_id uuid,p_primary uuid default null,p_policy text default null)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,1));
 if p_policy is not null then
  if p_policy not in ('everyone','primary_then_others') then raise exception 'INVALID_POLICY'; end if;
  update public.profiles set routing_policy=p_policy where id=p_user_id;
 end if;
 if p_primary is not null then
  if not exists(select 1 from public.trusted_contacts where id=p_primary and user_id=p_user_id and status='confirmed') then raise exception 'CONTACT_NOT_CONFIRMED'; end if;
  update public.trusted_contacts set is_primary=false where user_id=p_user_id and is_primary;
  update public.trusted_contacts set is_primary=true where id=p_primary;
 end if;
 return jsonb_build_object('policy',(select routing_policy from public.profiles where id=p_user_id),
  'contacts',coalesce((select jsonb_agg(jsonb_build_object('contactId',id,'name',name,'channel',channel,'status',status,'primary',is_primary) order by is_primary desc,created_at,id)
   from public.trusted_contacts where user_id=p_user_id),'[]'::jsonb));
end $$;
revoke all on function public.contact_network(uuid,uuid,text) from public;
grant execute on function public.contact_network(uuid,uuid,text) to authenticated;

create or replace function public.create_or_reuse_alert_legacy(
  p_user_id uuid,
  p_idempotency_key uuid,
  p_kind text,
  p_trigger_method text,
  p_viewer_token text,
  p_delivery_provider text,
  p_delivery_payload_ciphertext text,
  p_delivery_payload_key_version integer,
  p_location jsonb default null
)
returns table (
  event_id uuid,
  event_state text,
  delivery_status text,
  server_triggered_at timestamptz,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_contact_id uuid;
  v_event public.alert_events%rowtype;
  v_delivery_status text;
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;

  -- Serializes both same-key retries and distinct invocations inside the cooldown.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(p_user_id::text, 0));

  select * into v_event
  from public.alert_events
  where user_id = p_user_id and idempotency_key = p_idempotency_key;

  if found then
    select status into v_delivery_status
    from public.alert_deliveries
    where alert_event_id = v_event.id
    order by updated_at desc, created_at desc
    limit 1;

    return query select v_event.id, v_event.state, coalesce(v_delivery_status, 'queued'),
      v_event.triggered_at, true;
    return;
  end if;

  select id into v_contact_id
  from public.trusted_contacts
  where user_id = p_user_id and status = 'confirmed' and is_primary
  order by created_at desc
  limit 1;

  if v_contact_id is null then
    raise exception using errcode = 'P0001', message = 'CONTACT_NOT_CONFIRMED';
  end if;

  if p_delivery_provider not in ('fake', 'resend') or
    pg_catalog.char_length(p_delivery_payload_ciphertext) < 24 or
    p_delivery_payload_key_version < 1 or p_delivery_payload_key_version > 32767 then
    raise exception using errcode = '22023', message = 'INVALID_DELIVERY_CONFIGURATION';
  end if;

  -- A rate-limit decision persists in the event ledger and cannot be bypassed by
  -- moving the request between Edge Function instances.
  if (
    select count(*) from public.alert_events
    where user_id = p_user_id and kind = p_kind
      and triggered_at >= now() - interval '1 minute'
  ) >= 10 then
    raise exception using errcode = 'P0001', message = 'RATE_LIMITED';
  end if;

  select * into v_event
  from public.alert_events
  where user_id = p_user_id
    and kind = p_kind
    and state in ('pending', 'active')
    and triggered_at >= now() - interval '60 seconds'
  order by triggered_at desc
  limit 1;

  if found then
    select status into v_delivery_status
    from public.alert_deliveries
    where alert_event_id = v_event.id
    order by updated_at desc, created_at desc
    limit 1;

    return query select v_event.id, v_event.state, coalesce(v_delivery_status, 'queued'),
      v_event.triggered_at, true;
    return;
  end if;

  insert into public.alert_events (
    user_id, trusted_contact_id, idempotency_key, kind, state, trigger_method
  ) values (
    p_user_id, v_contact_id, p_idempotency_key, p_kind, 'active', p_trigger_method
  ) returning * into v_event;

  insert into public.viewer_tokens (alert_event_id, token_hash, expires_at)
  values (
    v_event.id,
    extensions.digest(pg_catalog.convert_to(p_viewer_token, 'UTF8'), 'sha256'),
    least(v_event.expires_at, now() + interval '24 hours')
  );

  insert into public.alert_deliveries (
    alert_event_id, provider, provider_idempotency_key, message_type,
    status, payload_ciphertext, payload_key_version
  ) values (
    v_event.id, p_delivery_provider, 'alert/' || v_event.id::text || '/initial', 'initial', 'queued',
    p_delivery_payload_ciphertext, p_delivery_payload_key_version::smallint
  )
  returning status into v_delivery_status;

  if p_location is not null then
    insert into public.location_samples (
      alert_event_id, captured_at, latitude, longitude,
      horizontal_accuracy_m, expires_at
    ) values (
      v_event.id,
      (p_location->>'capturedAt')::timestamptz,
      (p_location->>'latitude')::double precision,
      (p_location->>'longitude')::double precision,
      (p_location->>'horizontalAccuracyM')::double precision,
      least(v_event.expires_at, now() + interval '24 hours')
    );
  end if;

  return query select v_event.id, v_event.state, v_delivery_status,
    v_event.triggered_at, false;
end;
$$;


create function public.create_routed_alert(
 p_user_id uuid,p_idempotency_key uuid,p_kind text,p_trigger_method text,
 p_delivery_provider text,p_recipients jsonb,p_location jsonb default null,p_client_triggered_at timestamptz default null
) returns table(event_id uuid,event_state text,delivery_status text,server_triggered_at timestamptz,reused boolean)
language plpgsql security definer set search_path='' as $$
declare r record; c record; payload jsonb; n integer:=0; policy text; due timestamptz;
begin
 if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,1));
 perform 1 from public.trusted_contacts where user_id=p_user_id order by id for update;
 if jsonb_typeof(p_recipients) is distinct from 'array' or jsonb_array_length(p_recipients)<>3 then raise exception 'INVALID_RECIPIENT_PAYLOAD'; end if;
 -- The authenticated API generates and encrypts three independent capabilities.
 -- Identity/routing is selected here, never from client supplied contact IDs.
 for payload in select value from jsonb_array_elements(p_recipients) loop
  if length(payload->>'token')<>43 or length(payload->>'ciphertext')<24 or
   (payload->>'keyVersion')::integer not between 1 and 32767 then raise exception 'INVALID_RECIPIENT_PAYLOAD'; end if;
 end loop;
 payload:=p_recipients->0;
 select * into r from public.create_or_reuse_alert(p_user_id,p_idempotency_key,p_kind,p_trigger_method,payload->>'token',
 p_delivery_provider,payload->>'ciphertext',(payload->>'keyVersion')::integer,p_location,p_client_triggered_at);
 if not r.reused then
  select routing_policy into policy from public.profiles where id=p_user_id;
  update public.alert_events set routing_policy=policy where id=r.event_id;
  for c in select * from public.trusted_contacts where user_id=p_user_id and status='confirmed' order by is_primary desc,created_at,id loop
   if not c.is_primary then
    n:=n+1; payload:=p_recipients->n;
    due:=r.server_triggered_at + case when policy='primary_then_others' then interval '2 minutes' else interval '0' end;
    insert into public.viewer_tokens(alert_event_id,trusted_contact_id,token_hash,expires_at)
     select id,c.id,extensions.digest(convert_to(payload->>'token','UTF8'),'sha256'),expires_at from public.alert_events where id=r.event_id;
    insert into public.alert_deliveries(alert_event_id,trusted_contact_id,provider,provider_idempotency_key,message_type,payload_ciphertext,payload_key_version,next_attempt_at)
     values(r.event_id,c.id,p_delivery_provider,'alert/'||r.event_id::text||'/'||c.id::text||'/initial','initial',payload->>'ciphertext',(payload->>'keyVersion')::smallint,due);
   end if;
  end loop;
 end if;
 return query select r.event_id,r.event_state,r.delivery_status,r.server_triggered_at,r.reused;
end $$;
revoke all on function public.create_routed_alert(uuid,uuid,text,text,text,jsonb,jsonb,timestamptz) from public;
grant execute on function public.create_routed_alert(uuid,uuid,text,text,text,jsonb,jsonb,timestamptz) to authenticated;

-- Reissuing an invitation invalidates the earlier unclaimed verification,
-- even when it targets the same encrypted destination.
create or replace function public.invalidate_contact_deliveries()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in ('disabled','pending') or new.destination_ciphertext is distinct from old.destination_ciphertext then
  update public.alert_deliveries d set status='failed',completed_at=now(),last_error_code='CONTACT_WITHDRAWN',lease_owner=null,lease_expires_at=null
  where d.trusted_contact_id=old.id and d.status='queued';
  update public.viewer_tokens set revoked_at=coalesce(revoked_at,now()) where trusted_contact_id=old.id;
  update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='CONTACT_REPLACED',lease_owner=null,lease_expires_at=null
  where trusted_contact_id=old.id and status='queued';
 end if;
 return new;
end $$;

create or replace function public.disable_contact(p_user_id uuid, p_contact_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is distinct from p_user_id then
    raise exception using errcode = '42501', message = 'NOT_AUTHORIZED';
  end if;
  update public.trusted_contacts
    set status = 'disabled', confirmed_at = null
    where id = p_contact_id and user_id = p_user_id and status <> 'disabled';
  if found then
    delete from public.contact_confirmation_tokens where trusted_contact_id = p_contact_id;
    update public.viewer_tokens token set revoked_at = coalesce(token.revoked_at, now())
      from public.alert_events event
      where token.trusted_contact_id = p_contact_id and token.alert_event_id = event.id;
    return true;
  end if;
  return exists(select 1 from public.trusted_contacts where id = p_contact_id and user_id = p_user_id);
end;
$$;

revoke all on function public.disable_contact(uuid, uuid) from public;
grant execute on function public.disable_contact(uuid, uuid) to authenticated;


create or replace function public.withdraw_contact(p_token_hash bytea)
returns boolean language plpgsql security definer set search_path = '' as $$
declare v_contact_id uuid;
begin
  select t.trusted_contact_id into v_contact_id
  from public.contact_confirmation_tokens t
  where t.token_hash = p_token_hash and t.consumed_at is not null
  for update;
  if v_contact_id is null then return false; end if;
  if exists(select 1 from public.trusted_contacts where id = v_contact_id and status = 'disabled') then
    return true;
  end if;

  update public.trusted_contacts
  set status = 'disabled', confirmed_at = null
  where id = v_contact_id and status = 'confirmed';
  if not found then return false; end if;
  update public.viewer_tokens token set revoked_at = coalesce(token.revoked_at, now())
  from public.alert_events event
  where token.trusted_contact_id = v_contact_id and token.alert_event_id = event.id;
  return true;
end $$;
revoke all on function public.withdraw_contact(bytea) from public;
grant execute on function public.withdraw_contact(bytea) to anon, authenticated;


create or replace function public.acknowledge_public_event(p_token_hash bytea)
returns boolean language plpgsql security definer set search_path='' as $$
declare v_id uuid; v_token uuid;
begin
 select e.id,t.id into v_id,v_token from public.viewer_tokens t join public.alert_events e on e.id=t.alert_event_id
 where t.token_hash=p_token_hash and t.revoked_at is null and t.expires_at>now() and e.expires_at>now()
 and e.state in ('active','resolved') for update of t;
 if v_id is null then return false; end if;
 update public.viewer_tokens set acknowledged_at=coalesce(acknowledged_at,now()) where id=v_token;
 -- Keep the legacy aggregate field; it never controls escalation.
 update public.alert_events set acknowledged_at=coalesce(acknowledged_at,now()) where id=v_id;
 return true;
end $$;
create or replace function public.get_public_event(p_token_hash bytea)
returns table(projection jsonb) language sql stable security definer set search_path='' as $$
 select old.projection || jsonb_strip_nulls(jsonb_build_object('acknowledgedAt',t.acknowledged_at,
 'serverNow',now(),'clientTriggeredAt',e.client_triggered_at))
 from public.get_public_event_before_ack(p_token_hash) old
 join public.viewer_tokens t on t.token_hash=p_token_hash join public.alert_events e on e.id=t.alert_event_id;
$$;

alter table public.viewer_tokens add column recipient_name text;
update public.viewer_tokens t set recipient_name=c.name from public.trusted_contacts c where c.id=t.trusted_contact_id;
create or replace function public.assign_legacy_viewer_recipient() returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.trusted_contact_id:=coalesce(new.trusted_contact_id,(select trusted_contact_id from public.alert_events where id=new.alert_event_id));
 select c.name into new.recipient_name from public.alert_events e join public.trusted_contacts c on c.user_id=e.user_id
 where e.id=new.alert_event_id and c.id=new.trusted_contact_id;
 if not found then raise exception 'RECIPIENT_OWNER_MISMATCH'; end if;
 return new;
end $$;

create function public.recipient_progress(p_user_id uuid,p_event_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('contactId',t.trusted_contact_id,'name',t.recipient_name,
 'acknowledgedAt',t.acknowledged_at,'revoked',t.revoked_at is not null,'scheduledAt',d.scheduled_at,
 'delivery',case when d.last_error_code='OUTCOME_UNKNOWN' then 'unknown' else d.status end,
 'failureCode',d.last_error_code,
 'resolutionDelivery',(select r.status from public.alert_deliveries r where r.alert_event_id=e.id and r.trusted_contact_id=t.trusted_contact_id and r.message_type='resolved' limit 1))) order by t.created_at,t.id),'[]'::jsonb)
 from public.alert_events e join public.viewer_tokens t on t.alert_event_id=e.id
 join public.alert_deliveries d on d.alert_event_id=e.id and d.trusted_contact_id=t.trusted_contact_id and d.message_type='initial'
 where e.id=p_event_id and e.user_id=p_user_id and auth.uid()=p_user_id;
$$;
revoke all on function public.recipient_progress(uuid,uuid) from public;
grant execute on function public.recipient_progress(uuid,uuid) to authenticated;

create or replace function public.resolve_alert(p_user_id uuid,p_event_id uuid)
returns table(event_id uuid,event_state text,event_resolved_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare e public.alert_events%rowtype;
begin
 if auth.uid() is distinct from p_user_id then raise exception 'NOT_AUTHORIZED' using errcode='42501'; end if;
 select * into e from public.alert_events where id=p_event_id and user_id=p_user_id for update;
 if not found then raise exception 'EVENT_NOT_FOUND' using errcode='P0002'; end if;
 if e.state='expired' or e.expires_at<=now() then raise exception 'EVENT_NOT_ACTIVE'; end if;
 if e.state<>'resolved' then
  update public.alert_events set state='resolved',resolved_at=now() where id=e.id returning * into e;
  -- Never start an initial notification after resolution. Already claimed sends
  -- may be in flight; retain their correlation and follow with a resolution.
  update public.alert_deliveries set status='failed',completed_at=now(),last_error_code='EVENT_RESOLVED'
   where alert_event_id=e.id and message_type='initial' and status='queued' and lease_owner is null;
  insert into public.alert_deliveries(alert_event_id,trusted_contact_id,provider,provider_idempotency_key,message_type,payload_ciphertext,payload_key_version)
   select e.id,d.trusted_contact_id,d.provider,'alert/'||e.id::text||'/'||d.trusted_contact_id::text||'/resolved','resolved',d.payload_ciphertext,d.payload_key_version
   from public.alert_deliveries d join public.trusted_contacts c on c.id=d.trusted_contact_id
   where d.alert_event_id=e.id and d.message_type='initial' and c.status='confirmed'
   and (d.status in ('sent','delivered') or d.lease_owner is not null or d.last_error_code='OUTCOME_UNKNOWN')
   on conflict(provider_idempotency_key) do nothing;
 end if;
 return query select e.id,e.state,e.resolved_at;
end $$;
create or replace function public.claim_alert_deliveries_without_name(
  p_worker_id uuid,
  p_limit integer default 1
)
returns table (
  delivery_id uuid,
  event_id uuid,
  kind text,
  message_type text,
  provider text,
  provider_idempotency_key text,
  payload_ciphertext text,
  payload_key_version smallint,
  destination_ciphertext text,
  destination_key_version smallint,
  attempt_count integer
)
language sql
security definer
set search_path = ''
as $$
  with candidates as (
    select delivery.id
    from public.alert_deliveries delivery
    join public.alert_events incident on incident.id=delivery.alert_event_id
    where delivery.status = 'queued'
      and delivery.created_at > now() - interval '23 hours'
      and exists (select 1 from public.alert_events e join public.trusted_contacts c on c.id=delivery.trusted_contact_id
        where e.id=delivery.alert_event_id and e.expires_at>now() and c.status='confirmed' and (delivery.message_type='resolved' or e.state in ('pending','active')))
      and (delivery.message_type='initial' or exists (select 1 from public.alert_deliveries initial
        where initial.alert_event_id=delivery.alert_event_id and initial.trusted_contact_id=delivery.trusted_contact_id and initial.message_type='initial' and initial.status in ('sent','delivered')))
      and delivery.attempt_count < delivery.max_attempts
      and delivery.next_attempt_at <= now()
      and delivery.lease_owner is null and delivery.lease_expires_at is null
    order by (select e.kind='real' from public.alert_events e where e.id=delivery.alert_event_id) desc, delivery.next_attempt_at, delivery.created_at
    for update of delivery,incident skip locked
    limit least(greatest(p_limit, 1), 3)
  ), claimed as (
    update public.alert_deliveries delivery
    set lease_owner = p_worker_id,
      lease_expires_at = now() + interval '30 seconds',
      last_attempt_at = now(),
      attempt_count = delivery.attempt_count + 1,
      updated_at = now()
    from candidates
    where delivery.id = candidates.id
    returning delivery.*
  )
  select claimed.id, claimed.alert_event_id, event.kind, claimed.message_type,
    claimed.provider, claimed.provider_idempotency_key,
    claimed.payload_ciphertext, claimed.payload_key_version,
    claimed.destination_snapshot, claimed.destination_version,
    claimed.attempt_count
  from claimed
  join public.alert_events event on event.id = claimed.alert_event_id
  join public.trusted_contacts contact on contact.id = claimed.trusted_contact_id;
$$;

create or replace function public.recover_expired_delivery_leases() returns void language plpgsql security definer set search_path='' as $$
begin
 update public.alert_deliveries d set status='failed',completed_at=now(),last_error_code='EVENT_EXPIRED'
 from public.alert_events e where e.id=d.alert_event_id and e.expires_at<=now() and d.status='queued' and d.lease_owner is null;
 update public.alert_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (lease_owner is not null or attempt_count>=max_attempts or created_at<now()-interval '23 hours');
 update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null
 where status='queued' and (lease_expires_at is null or lease_expires_at<=now())
 and (lease_owner is not null or attempt_count>=max_attempts or created_at<now()-interval '30 minutes');
end $$;

