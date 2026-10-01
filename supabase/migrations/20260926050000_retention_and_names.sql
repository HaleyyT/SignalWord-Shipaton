-- Ciphertext snapshots must always exist for deliverable messages.
alter table public.alert_deliveries alter column destination_snapshot set not null, alter column destination_version set not null;
alter table public.contact_verification_deliveries alter column destination_snapshot set not null, alter column destination_version set not null;

create or replace function public.purge_expired_alert_data()
returns void language plpgsql security definer set search_path='' as $$
begin
 update public.alert_events set state='expired' where state in ('pending','active') and expires_at<=now();
 delete from public.location_samples where expires_at<=now();
 delete from public.viewer_tokens where expires_at<=now() or revoked_at is not null;
 delete from public.contact_confirmation_tokens where expires_at<=now() or consumed_at is not null;
 delete from public.rate_limit_buckets where expires_at<=now();
 delete from public.alert_deliveries where created_at<=now()-interval '7 days';
 delete from public.contact_verification_deliveries where created_at<=now()-interval '7 days';
 delete from public.delivery_webhook_receipts where received_at<=now()-interval '7 days';
 delete from public.alert_events where expires_at<=now()-interval '7 days';
end $$;
