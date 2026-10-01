begin;
set local signalword.local_fixture='true';

select plan(13);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '10000000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', 'rpc-a@example.test', '', now(), '{}', '{}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '20000000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', 'rpc-b@example.test', '', now(), '{}', '{}', now(), now());

insert into public.profiles (id, display_name) values
  ('10000000-0000-4000-8000-000000000001', 'User A'),
  ('20000000-0000-4000-8000-000000000002', 'User B');

insert into public.trusted_contacts (
  id, user_id, name, channel, destination_ciphertext, destination_fingerprint,
  status, confirmed_at
) values
  ('11000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000001',
   'Contact A', 'email', 'cipher-a', 'fingerprint-a', 'confirmed', now()),
  ('22000000-0000-4000-8000-000000000002', '20000000-0000-4000-8000-000000000002',
   'Contact B', 'email', 'cipher-b', 'fingerprint-b', 'confirmed', now());

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;

select lives_ok($$
  select * from public.create_or_reuse_alert(
    '10000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    'test', 'manual', repeat('a', 43), 'fake', repeat('x', 48), 1, null
  )
$$, 'authenticated user can create a test alert');
set local role authenticated;

reset role;
select is((select count(*) from public.alert_events), 1::bigint, 'first request creates one event');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$
  select * from public.create_or_reuse_alert(
    '10000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000001',
    'test', 'manual', repeat('z', 43), 'fake', repeat('y', 48), 1, null
  )
$$, 'same idempotency key is safely reused');
set local role authenticated;

reset role;
select is((select count(*) from public.alert_events), 1::bigint, 'idempotent retry creates no event');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-4000-8000-000000000001', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$
  select * from public.create_or_reuse_alert(
    '10000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000002',
    'real', 'vocalShortcut', repeat('b', 43), 'fake', repeat('w', 48), 1, null
  )
$$, 'a recent test alert never suppresses a real alert');
set local role authenticated;

reset role;
select is((select count(*) from public.alert_events), 2::bigint, 'test and real alerts are distinct canonical events');
select is((select count(*) from public.alert_deliveries), 2::bigint, 'each canonical event owns one outbox row');
select is((select count(*) from public.viewer_tokens), 2::bigint, 'each canonical event owns one hashed viewer token');

set local role authenticated;
select set_config('request.jwt.claim.sub', '20000000-0000-4000-8000-000000000002', true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select throws_ok($$
  select * from public.create_or_reuse_alert(
    '10000000-0000-4000-8000-000000000001',
    '30000000-0000-4000-8000-000000000003',
    'real', 'manual', repeat('c', 43), 'fake', repeat('v', 48), 1, null
  )
$$, '42501', 'NOT_AUTHORIZED', 'user B cannot create an alert for user A');
set local role authenticated;

reset role;
select is(
  (select count(*) from public.get_public_event(extensions.digest(convert_to(repeat('b', 43), 'UTF8'), 'sha256'))),
  1::bigint,
  'valid unexpired token resolves one projection'
);

insert into public.location_samples (
  alert_event_id, captured_at, received_at, latitude, longitude,
  horizontal_accuracy_m, expires_at
)
select id, now() - interval '5 minutes', now(), -33.8, 151.2, 10, now() + interval '1 hour'
from public.alert_events where kind = 'real';
select is(
  (select projection #>> '{location,freshness}'
   from public.get_public_event(extensions.digest(convert_to(repeat('b', 43), 'UTF8'), 'sha256'))),
  'stale',
  'a newly received old capture remains stale'
);

update public.viewer_tokens
set expires_at = now() - interval '1 second'
where token_hash = extensions.digest(convert_to(repeat('a', 43), 'UTF8'), 'sha256');
select is(
  (select count(*) from public.get_public_event(extensions.digest(convert_to(repeat('a', 43), 'UTF8'), 'sha256'))),
  0::bigint,
  'expired token resolves no projection'
);

update public.viewer_tokens
set revoked_at = now()
where token_hash = extensions.digest(convert_to(repeat('b', 43), 'UTF8'), 'sha256');
select is(
  (select count(*) from public.get_public_event(extensions.digest(convert_to(repeat('b', 43), 'UTF8'), 'sha256'))),
  0::bigint,
  'revoked token resolves no projection'
);

select * from finish();
rollback;
