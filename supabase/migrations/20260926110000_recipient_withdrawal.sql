-- A confirmed recipient may reuse the original high-entropy confirmation
-- capability to withdraw later. Replacement and deletion remove the token.
create function public.withdraw_contact(p_token_hash bytea)
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
  where event.trusted_contact_id = v_contact_id and token.alert_event_id = event.id;
  return true;
end $$;
revoke all on function public.withdraw_contact(bytea) from public;
grant execute on function public.withdraw_contact(bytea) to anon, authenticated;

create or replace function public.purge_expired_alert_data()
returns void language plpgsql security definer set search_path='' as $$
begin
 update public.alert_events set state='expired' where state in ('pending','active') and expires_at<=now();
 delete from public.location_samples where expires_at<=now();
 delete from public.viewer_tokens where expires_at<=now() or revoked_at is not null;
 -- Keep consumed capabilities for withdrawal until replacement, disable, or account deletion.
 delete from public.contact_confirmation_tokens where expires_at<=now() and consumed_at is null;
 delete from public.rate_limit_buckets where expires_at<=now();
 delete from public.alert_deliveries where created_at<=now()-interval '7 days';
 delete from public.contact_verification_deliveries where created_at<=now()-interval '7 days';
 delete from public.delivery_webhook_receipts where received_at<=now()-interval '7 days';
 delete from public.alert_events where expires_at<=now()-interval '7 days';
end $$;
