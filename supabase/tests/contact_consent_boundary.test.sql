begin;
set local signalword.local_fixture='true';
select no_plan();

insert into auth.users (id) values ('81000000-0000-4000-8000-000000000001');
insert into public.profiles (id, display_name)
values ('81000000-0000-4000-8000-000000000001', 'Consent boundary test');

-- A malicious sender could previously choose this hash through the RPC,
-- then call confirm_contact themselves without opening the recipient's email.
set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-4000-8000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok($$select * from public.create_or_replace_contact(
  '81000000-0000-4000-8000-000000000001', 'Recipient', 'email',
  repeat('d',48), repeat('f',64), 1, extensions.digest('attacker-known-token','sha256'),
  repeat('c',48), 1, 'fake')$$,
  '42501', 'permission denied for function create_or_replace_contact',
  'authenticated sender cannot choose their own consent capability');
select is(public.confirm_contact(extensions.digest('attacker-known-token','sha256')), false,
  'self-confirmation cannot succeed after the forbidden write');
reset role;
select is((select count(*) from public.trusted_contacts), 0::bigint,
  'forbidden write creates no contact');
select is((select count(*) from public.contact_verification_deliveries), 0::bigint,
  'forbidden write queues no email');
select is(has_function_privilege('anon',
  'public.create_or_replace_contact(uuid,text,text,text,text,integer,bytea,text,integer,text)', 'EXECUTE'),
  false, 'unsigned callers also cannot mint consent');

set local role service_role;
select set_config('request.jwt.claim.role', 'service_role', true);
select lives_ok($$select * from public.create_or_replace_contact(
  '81000000-0000-4000-8000-000000000001', 'Recipient', 'email',
  repeat('d',48), repeat('f',64), 1, extensions.digest('server-generated-token','sha256'),
  repeat('c',48), 1, 'fake')$$,
  'backend can create a pending contact for an authenticated sender');
reset role;
select is((select status from public.trusted_contacts), 'pending',
  'backend creation alone does not establish consent');

set local role anon;
select is(public.confirm_contact(extensions.digest('attacker-known-token','sha256')), false,
  'unissued capability cannot confirm the backend-created contact');
select is(public.confirm_contact(extensions.digest('server-generated-token','sha256')), true,
  'recipient holding the actual capability can confirm');
reset role;
select is((select status from public.trusted_contacts), 'confirmed',
  'normal confirmation journey still works');

select * from finish();
rollback;
