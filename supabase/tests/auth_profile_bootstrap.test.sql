begin;
set local signalword.local_fixture='true';

select plan(6);

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000000', '61000000-0000-4000-8000-000000000001',
   'authenticated', 'authenticated', null, '', '{}', '{"signalword_client": true}', now(), now()),
  ('00000000-0000-0000-0000-000000000000', '62000000-0000-4000-8000-000000000002',
   'authenticated', 'authenticated', null, '', '{}', '{}', now(), now());

select is((select count(*) from public.profiles where id = '61000000-0000-4000-8000-000000000001'),
  1::bigint, 'a marked SignalWord identity receives one profile');
select is((select display_name from public.profiles where id = '61000000-0000-4000-8000-000000000001'),
  'SignalWord user', 'bootstrap stores no user-supplied personal data');
select is((select count(*) from public.profiles where id = '62000000-0000-4000-8000-000000000002'),
  0::bigint, 'unrelated auth identities are not changed');

set local role authenticated;
select set_config('request.jwt.claim.sub', '61000000-0000-4000-8000-000000000001', true);
select is((select count(*) from public.profiles), 1::bigint,
  'the new identity can read only its own bootstrapped profile');
reset role;

delete from auth.users where id = '61000000-0000-4000-8000-000000000001';
select is((select count(*) from public.profiles where id = '61000000-0000-4000-8000-000000000001'),
  0::bigint, 'deleting auth identity cascades the profile');
select function_privs_are('public', 'bootstrap_signalword_profile', array[]::text[], 'public', array[]::text[],
  'public roles cannot execute the trigger function');

select * from finish();
rollback;
