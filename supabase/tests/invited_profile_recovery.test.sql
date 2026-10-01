begin;
set local signalword.local_fixture='true';
select no_plan();
insert into auth.users(id,aud,role,email,email_confirmed_at,raw_user_meta_data)
values ('81000000-0000-4000-8000-000000000001','authenticated','authenticated','invited@example.test',now(),'{}'),
('81000000-0000-4000-8000-000000000002','authenticated','authenticated','other@example.test',now(),'{}'),
('81000000-0000-4000-8000-000000000003','authenticated','authenticated','unconfirmed@example.test',null,'{}');
select is((select count(*) from public.profiles where id::text like '81000000%'),0::bigint,'admin users start without profiles');
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select is(public.signalword_profile('81000000-0000-4000-8000-000000000001')->>'displayName','SignalWord user','confirmed invited account can initialize its own profile');
select is(public.signalword_profile('81000000-0000-4000-8000-000000000001','Reviewer')->>'displayName','Reviewer','profile can then be named');
select is(public.signalword_profile('81000000-0000-4000-8000-000000000001')->>'displayName','Reviewer','repeat initialization preserves existing name');
select throws_ok($$select public.signalword_profile('81000000-0000-4000-8000-000000000002','Other')$$,'42501','NOT_AUTHORIZED','cannot create another user profile');
reset role;
select is((select count(*) from public.profiles where id='81000000-0000-4000-8000-000000000002'),0::bigint,'other identity stays untouched');
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000003',true);
select throws_ok($$select public.signalword_profile('81000000-0000-4000-8000-000000000003')$$,'42501','NOT_AUTHORIZED','unconfirmed identity cannot bootstrap');
reset role;
update public.profiles set deleted_at=now() where id='81000000-0000-4000-8000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
select throws_ok($$select public.signalword_profile('81000000-0000-4000-8000-000000000001')$$,'P0001','ACCOUNT_DELETION_PENDING','deleted profile cannot be revived');
reset role;
insert into public.pending_deletions(user_id,receipt_hash) values('81000000-0000-4000-8000-000000000002',decode(repeat('01',32),'hex'));
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000002',true);
select throws_ok($$select public.signalword_profile('81000000-0000-4000-8000-000000000002')$$,'P0001','ACCOUNT_DELETION_PENDING','deletion tombstone prevents initialization without a profile');
reset role;
select function_privs_are('public','signalword_profile',array['uuid','text'],'anon',array[]::text[],'anonymous callers have no execute grant');
select * from finish();
rollback;
