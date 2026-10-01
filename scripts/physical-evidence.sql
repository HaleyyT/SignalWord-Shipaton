-- Operator-only, read-only. Supply controlled event_id with psql -v; never a capability.
-- Keep raw UUID mapping private; hash this output before attaching it to a report.
\set ON_ERROR_STOP on
begin read only;
select id as event_id, kind, state, triggered_at, resolved_at,
  (select count(*) from public.viewer_tokens t where t.alert_event_id=e.id) as recipients,
  (select count(*) from public.viewer_tokens t where t.alert_event_id=e.id and t.acknowledged_at is not null) as acknowledgements,
  (select count(*) from public.viewer_tokens t where t.alert_event_id=e.id and t.revoked_at is not null) as revoked
from public.alert_events e where id=:'event_id'::uuid;
select d.id as delivery_id,d.message_type,d.status,d.attempt_count,
 d.created_at,d.completed_at,
 (select count(*) from public.delivery_webhook_receipts r where r.provider_message_id=d.provider_message_id and r.event_type='sent') as signed_sent_receipts,
 (select count(*) from public.delivery_webhook_receipts r where r.provider_message_id=d.provider_message_id and r.event_type='delivered') as signed_delivered_receipts
from public.alert_deliveries d where alert_event_id=:'event_id'::uuid order by created_at,id;
select id as recipient_record,acknowledged_at,revoked_at
from public.viewer_tokens where alert_event_id=:'event_id'::uuid order by id;
commit;
