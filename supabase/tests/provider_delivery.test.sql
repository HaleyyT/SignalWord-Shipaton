begin;
set local signalword.local_fixture='true';

select plan(18);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values (
  '00000000-0000-0000-0000-000000000000', '51000000-0000-4000-8000-000000000001',
  'authenticated', 'authenticated', 'provider@example.test', '', now(), '{}', '{}', now(), now()
);
insert into public.profiles (id, display_name)
values ('51000000-0000-4000-8000-000000000001', 'Provider Test');
insert into public.trusted_contacts (
  id, user_id, name, channel, destination_ciphertext, destination_fingerprint,
  destination_key_version, status, confirmed_at
) values (
  '52000000-0000-4000-8000-000000000002', '51000000-0000-4000-8000-000000000001',
  'Trusted', 'email', repeat('d', 48), repeat('f', 64), 1, 'confirmed', now()
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '51000000-0000-4000-8000-000000000001', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$
  select * from public.create_or_reuse_alert(
    '51000000-0000-4000-8000-000000000001',
    '53000000-0000-4000-8000-000000000003', 'real', 'manual',
    repeat('v', 43), 'resend', repeat('p', 48), 1, null
  )
$$, 'a resend alert is transactionally queued');
set local role authenticated;

reset role;
select set_config('test.alert_delivery_id', (select id::text from public.alert_deliveries), true);
set local role service_role;
select is(
  (select count(*) from public.claim_alert_deliveries('54000000-0000-4000-8000-000000000004', 10)),
  1::bigint, 'service worker claims one alert'
);
reset role;
select is((select attempt_count from public.alert_deliveries), 1, 'claim increments attempt count once');
select is((select lease_owner from public.alert_deliveries),
  '54000000-0000-4000-8000-000000000004'::uuid, 'claim owns a bounded lease');
set local role service_role;
select is((select destination_ciphertext from public.claim_alert_deliveries(
  '55000000-0000-4000-8000-000000000005', 10) limit 1), null::text,
  'a live lease prevents a second worker claim');
select is(public.finish_alert_delivery(
  current_setting('test.alert_delivery_id')::uuid, '54000000-0000-4000-8000-000000000004',
  false, null, 'TEMPORARY', true
), true, 'retryable failure finalizes the owned attempt');
reset role;
select is((select status from public.alert_deliveries), 'queued', 'retryable failure returns to queue');
select ok((select next_attempt_at > now() from public.alert_deliveries), 'retry is delayed');

update public.alert_deliveries set next_attempt_at = now() - interval '1 second';
set local role service_role;
select is(
  (select destination_ciphertext from public.claim_alert_deliveries(
    '55000000-0000-4000-8000-000000000005', 10) limit 1),
  repeat('d', 48), 'alert claim returns encrypted destination only'
);
select is(public.finish_alert_delivery(
  current_setting('test.alert_delivery_id')::uuid, '55000000-0000-4000-8000-000000000005',
  false, null, 'REJECTED', false
), true, 'terminal failure finalizes immediately');
reset role;
select is((select status from public.alert_deliveries), 'failed', 'non-retryable failure is terminal');

insert into public.contact_verification_deliveries (
  id, trusted_contact_id, provider, provider_idempotency_key,
  payload_ciphertext, payload_key_version
) values (
  '56000000-0000-4000-8000-000000000006', '52000000-0000-4000-8000-000000000002',
  'resend', 'contact/52000000-0000-4000-8000-000000000002/verification/test', repeat('c', 48), 1
);
set local role service_role;
select is(
  (select destination_ciphertext from public.claim_contact_verification_deliveries(
    '57000000-0000-4000-8000-000000000007', 10) limit 1),
  repeat('d', 48), 'contact claim joins the encrypted destination'
);
select is(public.finish_contact_verification_delivery(
  '56000000-0000-4000-8000-000000000006', '57000000-0000-4000-8000-000000000007',
  true, 'provider-contact-message', null, true
), true, 'contact provider acceptance is recorded');
reset role;
select is((select status from public.contact_verification_deliveries), 'sent',
  'provider acceptance is not mislabeled as inbox delivery');
set local role service_role;
select is(public.apply_resend_webhook('webhook-1', 'provider-contact-message', 'delivered'), true,
  'verified delivery webhook is applied');
reset role;
select is((select status from public.contact_verification_deliveries), 'delivered',
  'delivery webhook reconciles contact delivery');
set local role service_role;
select is(public.apply_resend_webhook('webhook-1', 'provider-contact-message', 'delivered'), false,
  'replayed provider event is idempotently ignored');
reset role;
select is((select count(*) from public.delivery_webhook_receipts), 1::bigint,
  'one immutable receipt exists for a replayed event');

select * from finish();
rollback;
