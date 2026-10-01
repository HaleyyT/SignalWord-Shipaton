begin;
set local signalword.local_fixture='true';

select plan(56);

select has_table('public', 'profiles', 'profiles table exists');
select has_table('public', 'trusted_contacts', 'trusted contacts table exists');
select has_table('public', 'alert_events', 'alert events table exists');
select has_table('public', 'location_samples', 'location samples table exists');
select has_table('public', 'alert_deliveries', 'alert deliveries table exists');
select has_table('public', 'viewer_tokens', 'viewer tokens table exists');
select has_table('public', 'contact_confirmation_tokens', 'contact confirmation tokens table exists');
select has_table('public', 'rate_limit_buckets', 'rate-limit buckets table exists');

select is((select relrowsecurity from pg_class where oid = 'public.profiles'::regclass), true, 'profiles has RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.trusted_contacts'::regclass), true, 'contacts have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.alert_events'::regclass), true, 'events have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.location_samples'::regclass), true, 'locations have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.alert_deliveries'::regclass), true, 'deliveries have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.viewer_tokens'::regclass), true, 'viewer tokens have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.contact_confirmation_tokens'::regclass), true, 'confirmation tokens have RLS enabled');
select is((select relrowsecurity from pg_class where oid = 'public.rate_limit_buckets'::regclass), true, 'rate limits have RLS enabled');

select table_privs_are('public', 'trusted_contacts', 'anon', array[]::text[], 'anon has no contact privileges');
select table_privs_are('public', 'alert_events', 'anon', array[]::text[], 'anon has no event privileges');
select table_privs_are('public', 'location_samples', 'anon', array[]::text[], 'anon has no location privileges');
select table_privs_are('public', 'alert_deliveries', 'anon', array[]::text[], 'anon has no delivery privileges');
select table_privs_are('public', 'viewer_tokens', 'anon', array[]::text[], 'anon has no viewer-token privileges');
select table_privs_are('public', 'contact_confirmation_tokens', 'anon', array[]::text[], 'anon has no confirmation-token privileges');
select table_privs_are('public', 'rate_limit_buckets', 'anon', array[]::text[], 'anon has no rate-limit privileges');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-000000000003');

insert into public.profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000000001', 'User A'),
  ('00000000-0000-0000-0000-000000000002', 'User B'),
  ('00000000-0000-0000-0000-000000000003', 'Delete Me');

insert into public.trusted_contacts (
  id, user_id, name, channel, destination_ciphertext, destination_fingerprint, status, confirmed_at
) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', 'A Contact', 'email', 'cipher-a', 'fingerprint-a', 'confirmed', now()),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002', 'B Contact', 'email', 'cipher-b', 'fingerprint-b', 'confirmed', now()),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000003', 'C Contact', 'email', 'cipher-c', 'fingerprint-c', 'confirmed', now());

insert into public.alert_events (
  id, user_id, trusted_contact_id, idempotency_key, kind, state, trigger_method, triggered_at, expires_at
) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000001', 'test', 'active', 'manual', now(), now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000002', 'real', 'active', 'vocalShortcut', now(), now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', '30000000-0000-0000-0000-000000000003', 'test', 'active', 'manual', now(), now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000004', 'test', 'active', 'manual', now(), now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '30000000-0000-0000-0000-000000000005', 'test', 'active', 'manual', now() - interval '2 days', now() - interval '1 day');

insert into public.location_samples (
  alert_event_id, captured_at, latitude, longitude, horizontal_accuracy_m, expires_at
) values
  ('20000000-0000-0000-0000-000000000001', now(), -33.8688, 151.2093, 20, now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000002', now(), -37.8136, 144.9631, 30, now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000003', now(), -27.4698, 153.0251, 25, now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000005', now() - interval '2 days', -33.86, 151.20, 50, now() - interval '1 hour');

insert into public.viewer_tokens (alert_event_id, token_hash, expires_at) values
  ('20000000-0000-0000-0000-000000000001', digest('viewer-a', 'sha256'), now() + interval '24 hours'),
  ('20000000-0000-0000-0000-000000000003', digest('viewer-c', 'sha256'), now() + interval '24 hours');

insert into public.alert_deliveries (
  alert_event_id, provider, provider_idempotency_key, status,
  payload_ciphertext, payload_key_version
) values
  ('20000000-0000-0000-0000-000000000001', 'resend', 'alert/a/initial', 'queued', 'cipher-a', 1),
  ('20000000-0000-0000-0000-000000000002', 'resend', 'alert/b/initial', 'queued', 'cipher-b', 1),
  ('20000000-0000-0000-0000-000000000003', 'resend', 'alert/c/initial', 'queued', 'cipher-c', 1);

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000001', true);
select is((select count(*) from public.profiles), 1::bigint, 'user A sees only their profile');
select is((select count(*) from public.trusted_contacts), 1::bigint, 'user A sees only their contact');
select is((select count(*) from public.alert_events), 3::bigint, 'user A sees only their events');
select is((select count(*) from public.location_samples), 2::bigint, 'user A sees only their locations');
select is((select count(*) from public.alert_deliveries), 1::bigint, 'user A sees only their delivery diagnostics');
reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-000000000002', true);
select is((select display_name from public.profiles), 'User B', 'user B sees only their profile');
select is((select count(*) from public.trusted_contacts where user_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'user B cannot see user A contact');
select is((select count(*) from public.alert_events where user_id = '00000000-0000-0000-0000-000000000001'), 0::bigint, 'user B cannot see user A events');
select is((select count(*) from public.location_samples where alert_event_id = '20000000-0000-0000-0000-000000000001'), 0::bigint, 'user B cannot see user A location');
select is((select count(*) from public.alert_deliveries where alert_event_id = '20000000-0000-0000-0000-000000000001'), 0::bigint, 'user B cannot see user A delivery');
select throws_ok($$select * from public.viewer_tokens$$, '42501', 'permission denied for table viewer_tokens', 'authenticated clients cannot query raw viewer tokens');
reset role;

set local role anon;
select throws_ok($$select * from public.alert_events$$, '42501', 'permission denied for table alert_events', 'anonymous clients cannot query alert events');
reset role;

select throws_ok(
  $$insert into public.alert_events (user_id, trusted_contact_id, idempotency_key, kind, trigger_method, expires_at)
    values ('00000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', '30000000-0000-0000-0000-000000000099', 'real', 'manual', now() + interval '24 hours')$$,
  '23503',
  'insert or update on table "alert_events" violates foreign key constraint "alert_events_contact_owner_fk"',
  'an event cannot reference another user contact'
);

select lives_ok(
  $$insert into public.alert_deliveries (
      alert_event_id, provider, provider_idempotency_key, payload_ciphertext, payload_key_version
    ) values
      ('20000000-0000-0000-0000-000000000004', 'resend', 'alert/a4/initial', 'cipher-a4', 1),
      ('20000000-0000-0000-0000-000000000005', 'resend', 'alert/a5/initial', 'cipher-a5', 1)$$,
  'multiple queued deliveries may have null provider message IDs'
);
select is((select count(*) from public.alert_deliveries where provider_message_id is null), 5::bigint, 'queued deliveries with null provider message IDs are preserved');

update public.alert_deliveries set provider_message_id = 'provider-message-1', status = 'sent' where provider_idempotency_key = 'alert/a4/initial';
select throws_ok(
  $$update public.alert_deliveries set provider_message_id = 'provider-message-1', status = 'sent' where provider_idempotency_key = 'alert/a5/initial'$$,
  '23505',
  'duplicate key value violates unique constraint "alert_deliveries_provider_message_unique_idx"',
  'non-null provider message IDs remain unique per provider'
);

select throws_ok(
  $$update public.alert_events set resolved_at = now() where id = '20000000-0000-0000-0000-000000000001'$$,
  '23514',
  'new row for relation "alert_events" violates check constraint "alert_events_lifecycle_timestamp_check"',
  'unresolved events cannot carry a resolved timestamp'
);

select throws_ok(
  $$insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at)
    values ('10000000-0000-0000-0000-000000000001', decode('abcd', 'hex'), now() + interval '30 minutes')$$,
  '23514',
  'new row for relation "contact_confirmation_tokens" violates check constraint "contact_confirmation_tokens_token_hash_check"',
  'confirmation token hashes must contain 256 bits'
);

insert into public.contact_confirmation_tokens (trusted_contact_id, token_hash, expires_at, consumed_at)
values ('10000000-0000-0000-0000-000000000001', digest('confirmation-a', 'sha256'), now() + interval '30 minutes', now());
insert into public.rate_limit_buckets (scope, subject_hash, window_started_at, expires_at)
values ('ip', digest('192.0.2.1', 'sha256'), now() - interval '2 hours', now() - interval '1 hour');
update public.viewer_tokens set revoked_at = now() where alert_event_id = '20000000-0000-0000-0000-000000000001';
update public.alert_deliveries
set status = 'delivered', completed_at = now() - interval '8 days', created_at = now() - interval '8 days'
where provider_idempotency_key = 'alert/b/initial';

select lives_ok('select public.purge_expired_alert_data()', 'retention purge executes successfully');
select is((select count(*) from public.contact_confirmation_tokens where consumed_at is not null), 1::bigint, 'confirmed recipient capability remains available for withdrawal');
select is((select count(*) from public.rate_limit_buckets where expires_at <= now()), 0::bigint, 'expired rate-limit buckets are purged');
select is((select count(*) from public.location_samples where expires_at <= now()), 0::bigint, 'expired locations are purged');
select is((select count(*) from public.viewer_tokens where revoked_at is not null), 0::bigint, 'revoked viewer tokens are purged');
select is((select count(*) from public.alert_deliveries where created_at <= now() - interval '7 days'), 0::bigint, 'old terminal deliveries are purged');
select is((select state from public.alert_events where id = '20000000-0000-0000-0000-000000000005'), 'expired', 'elapsed active events become expired');

select lives_ok($$delete from public.profiles where id = '00000000-0000-0000-0000-000000000003'$$, 'profile deletion cascades without contact foreign-key conflicts');
select is((select count(*) from public.trusted_contacts where user_id = '00000000-0000-0000-0000-000000000003'), 0::bigint, 'profile deletion removes contacts');
select is((select count(*) from public.alert_events where user_id = '00000000-0000-0000-0000-000000000003'), 0::bigint, 'profile deletion removes events');
select is((select count(*) from public.location_samples where alert_event_id = '20000000-0000-0000-0000-000000000003'), 0::bigint, 'profile deletion removes locations');
select is((select count(*) from public.alert_deliveries where provider_idempotency_key = 'alert/c/initial'), 0::bigint, 'profile deletion removes deliveries');
select is((select count(*) from public.viewer_tokens where token_hash = digest('viewer-c', 'sha256')), 0::bigint, 'profile deletion removes viewer tokens');

select is((select count(*) from cron.job where jobname = 'signalword-hourly-retention'), 1::bigint, 'hourly retention job is scheduled exactly once');
select function_privs_are('public', 'purge_expired_alert_data', array[]::text[], 'public', array[]::text[], 'retention function is not executable by public');

select * from finish();

rollback;
