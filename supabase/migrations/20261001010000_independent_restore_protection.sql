-- The authority URL/reader credential live in Vault; the authority itself is
-- external to this database and starts quarantined. Missing authority fails closed.
create extension if not exists http with schema extensions;
create function public.require_safety_authority(p_subject uuid default null) returns void
language plpgsql security definer set search_path='' as $$
declare endpoint text; secret text; result extensions.http_response;
begin
 -- Explicit, privileged local fixtures only. PostgREST's authenticator and cron
 -- sessions cannot obtain this exemption through a client JWT or RPC parameter.
 if session_user='postgres' and current_setting('signalword.local_fixture',true)='true' then return; end if;
 select decrypted_secret into endpoint from vault.decrypted_secrets where name='signalword_control_url';
 select decrypted_secret into secret from vault.decrypted_secrets where name='signalword_control_reader';
 if endpoint is null or secret is null or length(secret)<32 or
   (endpoint !~ '^https://[^/?#]+$' and not(session_user='postgres' and endpoint ~ '^http://(host.docker.internal|[0-9.]+):[0-9]+$')) then
  raise exception 'SAFETY_AUTHORITY_UNAVAILABLE' using errcode='P0001';
 end if;
 perform extensions.http_set_curlopt('CURLOPT_TIMEOUT_MS','2000');
 select * into result from extensions.http(('GET',endpoint||'/gate',
  array[extensions.http_header('Authorization','Bearer '||secret),extensions.http_header('X-SignalWord-Subject',coalesce(p_subject::text,'')),extensions.http_header('X-SignalWord-Issued-At',coalesce(auth.jwt()->>'iat',''))],null,null)::extensions.http_request);
 if result.status<>200 or (result.content::jsonb->>'allowed') is distinct from 'true' then
  raise exception 'SAFETY_AUTHORITY_UNAVAILABLE' using errcode='P0001';
 end if;
exception when others then raise exception 'SAFETY_AUTHORITY_UNAVAILABLE' using errcode='P0001';
end $$;
revoke all on function public.require_safety_authority(uuid) from public,anon,authenticated;
create function public.safety_pre_request() returns void language plpgsql security definer set search_path='' as $$
begin
 -- These service-only maintenance RPCs must remain usable during quarantine.
 if auth.role()='service_role' and current_setting('request.path',true) in
 ('/rpc/signalword_operational_health','/rpc/journal_pending','/rpc/journal_mark_durable','/rpc/finish_journaled_deletion','/rpc/find_deletion_receipt','/rpc/reconcile_restore_journal','/rpc/restore_receipt_matches','/rpc/reconcile_resend_webhook') then return; end if;
 perform public.require_safety_authority(auth.uid());
end $$;
revoke all on function public.safety_pre_request() from public;
grant execute on function public.safety_pre_request() to anon,authenticated,service_role;
alter role authenticator set pgrst.db_pre_request='public.safety_pre_request';
notify pgrst,'reload config';

alter table public.trusted_contacts add column consent_generation bigint not null default 1;
create table public.safety_journal_outbox(
 id uuid primary key default gen_random_uuid(),user_id uuid not null,contact_id uuid,
 generation bigint,kind text not null check(kind in ('delete','withdraw')),
 created_at timestamptz not null default now(),durable_at timestamptz,
 check((kind='delete' and contact_id is null and generation is null) or (kind='withdraw' and contact_id is not null and generation>0))
);
create unique index safety_journal_consent_once on public.safety_journal_outbox(contact_id,generation) where kind='withdraw';
create unique index safety_journal_delete_once on public.safety_journal_outbox(user_id) where kind='delete';
create index safety_journal_pending_idx on public.safety_journal_outbox(created_at) where durable_at is null;
alter table public.safety_journal_outbox enable row level security;
revoke all on public.safety_journal_outbox from public,anon,authenticated;
create table public.pending_deletions(
 user_id uuid primary key,receipt_hash bytea unique not null check(octet_length(receipt_hash)=32),
 deletion_id uuid not null default gen_random_uuid(),created_at timestamptz not null default now(),completed_at timestamptz
);
alter table public.pending_deletions enable row level security;
revoke all on public.pending_deletions from public,anon,authenticated;

create function public.journal_consent_change() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if old.status='confirmed' and (tg_op='DELETE' or new.status<>'confirmed' or new.destination_fingerprint<>old.destination_fingerprint) then
  insert into public.safety_journal_outbox(user_id,contact_id,generation,kind)
  values(old.user_id,old.id,old.consent_generation,'withdraw') on conflict do nothing;
 end if;
 if tg_op='UPDATE' then
  if new.destination_fingerprint<>old.destination_fingerprint or (new.status='pending' and old.status<>'pending') then new.consent_generation:=old.consent_generation+1; end if;
  return new;
 end if;
 return old;
end $$;
revoke all on function public.journal_consent_change() from public;
create trigger journal_consent_change before update or delete on public.trusted_contacts for each row execute function public.journal_consent_change();

create function public.prepare_journaled_deletion(p_user_id uuid,p_receipt_hash bytea) returns uuid
language plpgsql security definer set search_path='' as $$
declare result uuid;
begin
 perform pg_advisory_xact_lock(hashtextextended(p_user_id::text,0));
 if not exists(select 1 from auth.users where id=p_user_id) then raise exception 'NOT_AUTHORIZED'; end if;
 insert into public.pending_deletions(user_id,receipt_hash) values(p_user_id,p_receipt_hash) on conflict(user_id) do nothing;
 select deletion_id into result from public.pending_deletions where user_id=p_user_id and receipt_hash=p_receipt_hash;
 if result is null then raise exception 'DELETION_RECEIPT_CONFLICT'; end if;
 insert into public.safety_journal_outbox(user_id,kind) values(p_user_id,'delete') on conflict do nothing;
 update public.trusted_contacts set status='disabled',confirmed_at=null where user_id=p_user_id and status<>'disabled';
 update public.viewer_tokens t set revoked_at=coalesce(t.revoked_at,now()) from public.alert_events e where e.id=t.alert_event_id and e.user_id=p_user_id;
 update public.check_in_timers set state='cancelled',updated_at=now(),recipient_payloads='[]'::jsonb where user_id=p_user_id and state='active';
 return result;
end $$;
revoke all on function public.prepare_journaled_deletion(uuid,bytea) from public,anon,authenticated;
grant execute on function public.prepare_journaled_deletion(uuid,bytea) to service_role;

create function public.journal_pending(p_user_id uuid default null,p_limit integer default 100) returns jsonb
language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object('id',id,'userId',user_id,'contactId',contact_id,'generation',generation,'kind',kind))),'[]'::jsonb)
 from (select * from public.safety_journal_outbox where durable_at is null and (p_user_id is null or user_id=p_user_id) order by created_at,id limit least(greatest(p_limit,1),100)) q;
$$;
create function public.journal_mark_durable(p_id uuid) returns void language sql security definer set search_path='' as $$
 update public.safety_journal_outbox set durable_at=coalesce(durable_at,now()) where id=p_id;
$$;
create function public.finish_journaled_deletion(p_user_id uuid default null) returns void language plpgsql security definer set search_path='' as $$
declare p record;
begin
 for p in select * from public.pending_deletions d where completed_at is null and (p_user_id is null or user_id=p_user_id)
 and exists(select 1 from public.safety_journal_outbox j where j.user_id=d.user_id and j.kind='delete' and j.durable_at is not null)
 and not exists(select 1 from public.safety_journal_outbox j where j.user_id=d.user_id and j.durable_at is null) for update skip locked loop
  insert into public.deletion_receipts(receipt_hash,deletion_id) values(p.receipt_hash,p.deletion_id) on conflict(receipt_hash) do nothing;
  delete from auth.users where id=p.user_id;
  update public.pending_deletions set completed_at=now() where user_id=p.user_id;
 end loop;
end $$;
revoke all on function public.journal_pending(uuid,integer),public.journal_mark_durable(uuid),public.finish_journaled_deletion(uuid) from public,anon,authenticated;
grant execute on function public.journal_pending(uuid,integer),public.journal_mark_durable(uuid),public.finish_journaled_deletion(uuid) to service_role;
-- No client or old backend may bypass the durable deletion protocol.
revoke all on function public.delete_my_account(uuid,bytea) from public,anon,authenticated,service_role;

create function public.guard_pending_deletion() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='trusted_contacts' and tg_op='UPDATE' then
  if new.status='disabled' then return new; end if;
 end if;
 if exists(select 1 from public.pending_deletions where user_id=new.user_id) then raise exception 'ACCOUNT_DELETION_PENDING'; end if;
 return new;
end $$;
revoke all on function public.guard_pending_deletion() from public;
create trigger guard_deleting_alert before insert on public.alert_events for each row execute function public.guard_pending_deletion();
create trigger guard_deleting_timer before insert on public.check_in_timers for each row execute function public.guard_pending_deletion();
create trigger guard_deleting_contact before insert or update of destination_fingerprint,confirmed_at on public.trusted_contacts for each row execute function public.guard_pending_deletion();

-- Claim functions are also used from schedules, outside PostgREST's pre-request hook.
do $migration$
declare f record; definition text;
begin
 for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
 and p.proname in ('claim_alert_deliveries_before_cause','claim_contact_verification_deliveries','sweep_check_ins') loop
  definition:=pg_get_functiondef(f.oid);
  definition:=regexp_replace(definition,'\mbegin\M','begin perform public.require_safety_authority();','i');
  execute definition;
 end loop;
end $migration$;

create table public.restore_reconciliation_receipts(restore_id uuid primary key,journal_version bigint not null,digest text not null,reconciled_at timestamptz not null default now());
alter table public.restore_reconciliation_receipts enable row level security;
revoke all on public.restore_reconciliation_receipts from public,anon,authenticated;
create function public.reconcile_restore_journal(p_restore_id uuid,p_version bigint,p_digest text,p_entries jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare e jsonb; r jsonb;
begin
 if jsonb_typeof(p_entries)<>'array' or length(p_digest)<>64 then raise exception 'INVALID_RESTORE_PROOF'; end if;
 -- Cancel restored work before any replay. Never infer that historical sends are safe to retry.
 update public.alert_deliveries set status='failed',completed_at=now(),last_error_code=case when attempt_count>0 then 'OUTCOME_UNKNOWN' else 'RESTORE_CANCELLED' end,lease_owner=null,lease_expires_at=null where status='queued';
 update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code=case when attempt_count>0 then 'OUTCOME_UNKNOWN' else 'RESTORE_CANCELLED' end,lease_owner=null,lease_expires_at=null where status='queued';
 update public.check_in_timers set state='cancelled',updated_at=now(),recipient_payloads='[]'::jsonb where state='active';
 update public.viewer_tokens set revoked_at=coalesce(revoked_at,now());
 delete from public.contact_confirmation_tokens;
 delete from auth.sessions;
 delete from auth.refresh_tokens;
 for e in select value from jsonb_array_elements(p_entries) loop
  r:=e->'input';
  if r->>'kind'='delete' then delete from auth.users where id=(r->>'userId')::uuid;
  elsif r->>'kind'='withdraw' then
   update public.trusted_contacts set status='disabled',confirmed_at=null where id=(r->>'contactId')::uuid and user_id=(r->>'userId')::uuid and consent_generation<=(r->>'generation')::bigint;
  else raise exception 'INVALID_JOURNAL_ENTRY'; end if;
 end loop;
 -- An accepted-but-unobserved send needs provider reconciliation, not a guessed
 -- failure. Roll back this replay and remain quarantined until receipts settle it.
 if exists(select 1 from public.alert_deliveries where last_error_code='OUTCOME_UNKNOWN')
 or exists(select 1 from public.contact_verification_deliveries where last_error_code='OUTCOME_UNKNOWN') then
  raise exception 'RESTORE_PROVIDER_RECONCILIATION_REQUIRED';
 end if;
 insert into public.restore_reconciliation_receipts values(p_restore_id,p_version,p_digest,now())
 on conflict(restore_id) do update set journal_version=excluded.journal_version,digest=excluded.digest,reconciled_at=excluded.reconciled_at;
end $$;
revoke all on function public.reconcile_restore_journal(uuid,bigint,text,jsonb) from public,anon,authenticated;
grant execute on function public.reconcile_restore_journal(uuid,bigint,text,jsonb) to service_role;

-- Authenticated service gateways must validate the caller through this RPC before
-- changing to service credentials. Restored access tokens cannot bypass the gate.
create function public.assert_current_session() returns boolean language sql security invoker set search_path='' as $$ select auth.uid() is not null; $$;
revoke all on function public.assert_current_session() from public,anon;
grant execute on function public.assert_current_session() to authenticated;

-- Scope public withdrawal persistence to the capability's account, not a global backlog.
create function public.withdrawal_journal_owner(p_token_hash bytea) returns uuid
language sql stable security definer set search_path='' as $$
 select c.user_id from public.contact_confirmation_tokens t join public.trusted_contacts c on c.id=t.trusted_contact_id where t.token_hash=p_token_hash limit 1;
$$;
revoke all on function public.withdrawal_journal_owner(bytea) from public,anon,authenticated;
grant execute on function public.withdrawal_journal_owner(bytea) to service_role;

create function public.restore_receipt_matches(p_restore_id uuid,p_version bigint,p_digest text) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.restore_reconciliation_receipts where restore_id=p_restore_id and journal_version=p_version and digest=p_digest);
$$;
revoke all on function public.restore_receipt_matches(uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.restore_receipt_matches(uuid,bigint,text) to service_role;
