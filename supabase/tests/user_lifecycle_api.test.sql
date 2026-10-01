begin;
set local signalword.local_fixture='true';

select no_plan();

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '41000000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', 'lifecycle-a@example.test', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '42000000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', 'lifecycle-b@example.test', '', now(), '{}', '{}', now(), now());

insert into public.profiles (id, display_name) values
  ('41000000-0000-4000-8000-000000000001', 'Lifecycle A'),
  ('42000000-0000-4000-8000-000000000002', 'Lifecycle B');

set local role service_role;
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);

select lives_ok($$
  select * from public.create_or_replace_contact(
    '41000000-0000-4000-8000-000000000001', 'Trusted A', 'email',
    repeat('d', 48), repeat('f', 64), 1,
    extensions.digest('confirm-a', 'sha256'), repeat('c', 48), 1, 'fake'
  )
$$, 'backend creates an encrypted pending contact for verified user A');

set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select is((select status from public.trusted_contacts where user_id = '41000000-0000-4000-8000-000000000001'),
  'pending', 'new contact is pending');
reset role;
select ok((select expires_at <= now() + interval '31 minutes' from public.contact_confirmation_tokens limit 1),
  'confirmation expires within thirty minutes');
set local role anon;
select is(public.confirm_contact(extensions.digest('confirm-a', 'sha256')), true,
  'valid confirmation is consumed');
reset role;
select is((select status from public.trusted_contacts where user_id = '41000000-0000-4000-8000-000000000001'),
  'confirmed', 'contact becomes confirmed');
set local role anon;
select is(public.confirm_contact(extensions.digest('confirm-a', 'sha256')), true,
  'lost confirmation response can be retried without granting consent twice');
select is(public.confirm_contact(extensions.digest('unknown-confirmation', 'sha256')), false,
  'unknown capability cannot report consent');
reset role;
update public.contact_confirmation_tokens set created_at=now()-interval '1 hour', expires_at=now()-interval '1 minute'
where token_hash=extensions.digest('confirm-a', 'sha256');
set local role anon;
select is(public.confirm_contact(extensions.digest('confirm-a', 'sha256')), false,
  'expired confirmation cannot be reused even when contact is confirmed');
reset role;

set local role service_role;
select set_config('request.jwt.claim.role', 'service_role', true);
select lives_ok($$
  select * from public.create_or_replace_contact(
    '41000000-0000-4000-8000-000000000001', 'Trusted A', 'email',
    repeat('d', 48), repeat('f', 64), 1,
    extensions.digest('confirm-a-resend', 'sha256'), repeat('c', 48), 1, 'fake'
  )
$$, 'sender can resend a confirmation to the same address');
reset role;
select is((select count(*) from public.contact_verification_deliveries where status='queued'), 1::bigint,
  'resend cancels the earlier unclaimed invitation');
set local role anon;
select is(public.confirm_contact(extensions.digest('confirm-a', 'sha256')), false,
  'replaced confirmation link cannot be reused');
select is(public.confirm_contact(extensions.digest('confirm-a-resend', 'sha256')), true,
  'new invitation can be confirmed');
reset role;

select set_config('request.jwt.claim.sub', '42000000-0000-4000-8000-000000000002', true);
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select is((select count(*) from public.get_my_contact('41000000-0000-4000-8000-000000000001')),
  0::bigint, 'user B cannot read user A contact through the RPC');
select throws_ok($$select public.disable_contact(
    '41000000-0000-4000-8000-000000000001',
    (select id from public.trusted_contacts where user_id = '41000000-0000-4000-8000-000000000001'))$$,
  '42501', 'NOT_AUTHORIZED', 'user B cannot disable user A contact');

select set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$
  select * from public.create_or_reuse_alert(
    '41000000-0000-4000-8000-000000000001',
    '43000000-0000-4000-8000-000000000003',
    'real', 'manual', repeat('v', 43), 'fake', repeat('p', 48), 1, null
  )
$$, 'confirmed user can create an alert');
set local role authenticated;
select is((select count(*) from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'),
  1::bigint, 'one alert exists');

select is((select accepted from public.append_alert_location(
  '41000000-0000-4000-8000-000000000001',
  (select id from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'),
  jsonb_build_object('capturedAt', now() - interval '2 days', 'latitude', -33.8,
    'longitude', 151.2, 'horizontalAccuracyM', 10)
)), false, 'implausibly old location is rejected without failing the alert');

select is((select accepted from public.append_alert_location(
  '41000000-0000-4000-8000-000000000001',
  (select id from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'),
  jsonb_build_object('capturedAt', now(), 'latitude', -33.8,
    'longitude', 151.2, 'horizontalAccuracyM', 10)
)), true, 'current valid location is accepted');
select is((select count(*) from public.location_samples), 1::bigint, 'only valid location is stored');

-- A resolution notification is needed only after initial submission. Unsent
-- initial messages are cancelled (covered independently by escalation tests).
reset role;
update public.alert_deliveries set status='sent',provider_message_id='lifecycle-submitted' where message_type='initial';
set local role authenticated;
select lives_ok($$select * from public.resolve_alert(
  '41000000-0000-4000-8000-000000000001',
  (select id from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'))$$,
  'owner can resolve active alert');
select is((select state from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'),
  'resolved', 'alert is resolved');
reset role;
select is((select count(*) from public.viewer_tokens where revoked_at is null), 1::bigint,
  'resolved viewer remains available during bounded resolution window');
select is((select count(*) from public.alert_deliveries where message_type = 'resolved'), 1::bigint,
  'resolution queues exactly one status delivery');
select set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
select lives_ok($$select * from public.resolve_alert(
  '41000000-0000-4000-8000-000000000001',
  (select id from public.alert_events where user_id = '41000000-0000-4000-8000-000000000001'))$$,
  'resolution is idempotent');
reset role;
select is((select count(*) from public.alert_deliveries where message_type = 'resolved'), 1::bigint,
  'idempotent resolution does not duplicate delivery');

select is((select count(*) from public.claim_alert_deliveries('45000000-0000-4000-8000-000000000005', 1)), 1::bigint,
  'one send can already be in flight when withdrawal arrives');

set local role anon;
select is(public.withdraw_contact(extensions.digest('confirm-a-resend', 'sha256')), true,
  'recipient can withdraw with the previously consumed confirmation capability');
select is(public.withdraw_contact(extensions.digest('confirm-a-resend', 'sha256')), true,
  'recipient withdrawal is idempotent after a lost response');
select is(public.confirm_contact(extensions.digest('confirm-a-resend', 'sha256')), false,
  'confirmation retry cannot restore withdrawn consent');
reset role;
select is((select status from public.trusted_contacts where user_id = '41000000-0000-4000-8000-000000000001'),
  'disabled', 'withdrawal disables future sends');
select is((select count(*) from public.alert_deliveries where status = 'queued'), 0::bigint,
  'withdrawal cancels unclaimed initial and resolution deliveries');
select is((select count(*) from public.viewer_tokens where revoked_at is null), 0::bigint,
  'withdrawal revokes existing viewer capabilities');
select is((select count(*) from public.claim_alert_deliveries(gen_random_uuid(), 1)), 0::bigint,
  'worker cannot claim a withdrawn recipient delivery');
select is(public.finish_alert_delivery(
  (select id from public.alert_deliveries where message_type='initial'),
  '45000000-0000-4000-8000-000000000005', true, 'accepted-before-withdrawal'), false,
  'late worker completion cannot revive a withdrawn delivery');

select set_config('request.jwt.claim.sub', '41000000-0000-4000-8000-000000000001', true);
set local role authenticated;
select set_config('request.jwt.claim.role', 'authenticated', true);
reset role;
select isnt(public.prepare_journaled_deletion('41000000-0000-4000-8000-000000000001', extensions.digest('saved-deletion-capability', 'sha256')), null,
  'deletion preparation returns an operation ID');
select is(public.find_deletion_receipt(extensions.digest('saved-deletion-capability', 'sha256')), null::uuid, 'preparation must not report deletion complete');
select public.finish_journaled_deletion();
select is((select count(*) from auth.users where id='41000000-0000-4000-8000-000000000001'),1::bigint,'un-journaled account is retained for resumption');
select public.journal_mark_durable(id) from public.safety_journal_outbox;
select public.finish_journaled_deletion();
reset role;
select is((select count(*) from auth.users where id = '41000000-0000-4000-8000-000000000001'),
  0::bigint, 'auth identity is deleted');
select isnt(public.find_deletion_receipt(extensions.digest('saved-deletion-capability', 'sha256')), null,
  'lost response can be reconciled after auth identity disappears');
select is(public.find_deletion_receipt(extensions.digest('wrong-capability', 'sha256')), null::uuid,
  'another capability cannot confirm this deletion');
select is(has_function_privilege('authenticated', 'public.delete_my_account(uuid)', 'EXECUTE'), false,
  'legacy deletion without a durable receipt is disabled');

select * from finish();
rollback;
