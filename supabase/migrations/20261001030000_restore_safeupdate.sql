-- Hosted PostgREST enables pg-safeupdate. Keep that protection enabled while
-- making the restore-only invalidation explicit. Every token/session row has a
-- non-null primary key; those predicates deliberately revoke all restored access.
-- Previously revoked viewer tokens retain their original revocation timestamp.
-- No data changes occur until the service-only restore RPC is explicitly called.
create or replace function public.reconcile_restore_journal(p_restore_id uuid,p_version bigint,p_digest text,p_entries jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare e jsonb; r jsonb;
begin
 if jsonb_typeof(p_entries)<>'array' or length(p_digest)<>64 then raise exception 'INVALID_RESTORE_PROOF'; end if;
 -- Cancel restored work before any replay. Never infer that historical sends are safe to retry.
 update public.alert_deliveries set status='failed',completed_at=now(),last_error_code=case when attempt_count>0 then 'OUTCOME_UNKNOWN' else 'RESTORE_CANCELLED' end,lease_owner=null,lease_expires_at=null where status='queued';
 update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code=case when attempt_count>0 then 'OUTCOME_UNKNOWN' else 'RESTORE_CANCELLED' end,lease_owner=null,lease_expires_at=null where status='queued';
 update public.check_in_timers set state='cancelled',updated_at=now(),recipient_payloads='[]'::jsonb where state='active';
 update public.viewer_tokens set revoked_at=now() where revoked_at is null;
 delete from public.contact_confirmation_tokens where id is not null;
 delete from auth.sessions where id is not null;
 delete from auth.refresh_tokens where id is not null;
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

