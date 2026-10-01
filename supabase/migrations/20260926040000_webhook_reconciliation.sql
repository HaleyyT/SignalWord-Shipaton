-- Reconcile immutable receipts even when a webhook beats worker completion.
create function public.reconcile_delivery_receipts() returns trigger language plpgsql security definer set search_path='' as $$
declare failure text; delivered boolean;
begin
 if new.provider_message_id is null or new.provider<>'resend' then return new; end if;
 select max(event_type) filter(where event_type in ('failed','bounced','complained')),
        bool_or(event_type='delivered') into failure,delivered
 from public.delivery_webhook_receipts where provider='resend' and provider_message_id=new.provider_message_id;
 if failure is not null then
  new.status:='failed'; new.last_error_code:=upper(failure); new.completed_at:=coalesce(new.completed_at,now());
 elsif TG_OP='UPDATE' and old.status='failed' and old.last_error_code is distinct from 'OUTCOME_UNKNOWN' then
  new.status:=old.status; new.last_error_code:=old.last_error_code; new.completed_at:=old.completed_at;
 elsif delivered then
  new.status:='delivered'; new.last_error_code:=null; new.completed_at:=coalesce(new.completed_at,now());
 end if;
 return new;
end $$;
revoke all on function public.reconcile_delivery_receipts() from public;
create trigger reconcile_alert_receipts before update on public.alert_deliveries for each row execute function public.reconcile_delivery_receipts();
create trigger reconcile_confirmation_receipts before update on public.contact_verification_deliveries for each row execute function public.reconcile_delivery_receipts();

-- Expose uncertainty separately from a known provider rejection.
create or replace function public.alert_details(p_user_id uuid,p_event_id uuid)
returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object(
  'eventId',e.id,'kind',e.kind,'state',case when e.expires_at<=now() then 'expired' else e.state end,
  'triggeredAt',e.triggered_at,'clientTriggeredAt',e.client_triggered_at,'resolvedAt',e.resolved_at,'acknowledgedAt',e.acknowledged_at,
  'delivery',coalesce((select case when d.last_error_code='OUTCOME_UNKNOWN' then 'unknown' else d.status end from public.alert_deliveries d where d.alert_event_id=e.id and d.message_type='initial' limit 1),'queued'),
  'resolutionDelivery',(select case when d.last_error_code='OUTCOME_UNKNOWN' then 'unknown' else d.status end from public.alert_deliveries d where d.alert_event_id=e.id and d.message_type='resolved' limit 1)))
 from public.alert_events e where e.id=p_event_id and e.user_id=p_user_id and auth.uid()=p_user_id;
$$;
