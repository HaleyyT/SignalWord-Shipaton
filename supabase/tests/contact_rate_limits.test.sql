begin;
set local signalword.local_fixture='true';

select plan(12);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
)
select '00000000-0000-0000-0000-000000000000',
  ('71000000-0000-4000-8000-00000000000' || n)::uuid,
  'authenticated', 'authenticated', 'rate-' || n || '@example.test', '', now(), '{}', '{}', now(), now()
from generate_series(1, 5) n;

insert into public.profiles (id, display_name)
select ('71000000-0000-4000-8000-00000000000' || n)::uuid, 'Rate user ' || n
from generate_series(1, 5) n;

set local role service_role;
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000001', true);

select lives_ok(format($sql$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000001', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('user-dest-%s', 'sha256'), 'hex'), 1,
  extensions.digest('user-token-%s', 'sha256'), repeat('c', 48), 1, 'fake')$sql$, n, n),
  'accepted contact setup ' || n || ' is within the per-user limit')
from generate_series(1, 5) n;

select throws_ok($$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000001', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('user-dest-6', 'sha256'), 'hex'), 1,
  extensions.digest('user-token-6', 'sha256'), repeat('c', 48), 1, 'fake')$$,
  'P0001', 'RATE_LIMITED', 'sixth contact setup is blocked for the same user');

reset role;
select is((select request_count from public.rate_limit_buckets where scope = 'user'),
  5, 'blocked attempt cannot roll back or increment the five accepted user requests');

set local role service_role;
select set_config('request.jwt.claim.role', 'service_role', true);
select set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000002', true);
select lives_ok($$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000002', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('shared-destination', 'sha256'), 'hex'), 1,
  extensions.digest('shared-token-2', 'sha256'), repeat('c', 48), 1, 'fake')$$,
  'first setup to a shared destination is accepted');
select set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000003', true);
select lives_ok($$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000003', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('shared-destination', 'sha256'), 'hex'), 1,
  extensions.digest('shared-token-3', 'sha256'), repeat('c', 48), 1, 'fake')$$,
  'second setup to a shared destination is accepted');
select set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000004', true);
select lives_ok($$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000004', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('shared-destination', 'sha256'), 'hex'), 1,
  extensions.digest('shared-token-4', 'sha256'), repeat('c', 48), 1, 'fake')$$,
  'third setup to a shared destination is accepted');
select set_config('request.jwt.claim.sub', '71000000-0000-4000-8000-000000000005', true);
select throws_ok($$select * from public.create_or_replace_contact(
  '71000000-0000-4000-8000-000000000005', 'Trusted', 'email', repeat('d', 48),
  encode(extensions.digest('shared-destination', 'sha256'), 'hex'), 1,
  extensions.digest('shared-token-5', 'sha256'), repeat('c', 48), 1, 'fake')$$,
  'P0001', 'RATE_LIMITED', 'fourth setup to the same destination is blocked');
reset role;

select is((select request_count from public.rate_limit_buckets
    where scope = 'destination'
      and subject_hash = extensions.digest('shared-destination', 'sha256')),
  3, 'destination bucket contains only the three accepted requests');

select * from finish();
rollback;
