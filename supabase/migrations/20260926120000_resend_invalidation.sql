-- Reissuing an invitation invalidates the earlier unclaimed verification,
-- even when it targets the same encrypted destination.
create or replace function public.invalidate_contact_deliveries()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status in ('disabled','pending') or new.destination_ciphertext is distinct from old.destination_ciphertext then
  update public.alert_deliveries d set status='failed',completed_at=now(),last_error_code='CONTACT_WITHDRAWN',lease_owner=null,lease_expires_at=null
  from public.alert_events e where e.id=d.alert_event_id and e.trusted_contact_id=old.id and d.status='queued';
  update public.contact_verification_deliveries set status='failed',completed_at=now(),last_error_code='CONTACT_REPLACED',lease_owner=null,lease_expires_at=null
  where trusted_contact_id=old.id and status='queued';
 end if;
 return new;
end $$;
