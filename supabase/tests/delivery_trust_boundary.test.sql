begin;
set local signalword.local_fixture='true';
select no_plan();
select ok(not has_function_privilege(r, p.oid, 'EXECUTE'),r||' cannot execute '||p.oid::regprocedure)
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
cross join (values ('anon'),('authenticated')) roles(r)
where n.nspname='public' and p.proname in
('create_or_reuse_alert','create_or_reuse_alert_legacy','create_routed_alert','change_check_in',
'gateway_create_or_reuse_alert','gateway_create_routed_alert','gateway_change_check_in');
set local role authenticated;
select throws_ok($$select public.change_check_in(gen_random_uuid(),gen_random_uuid(),'start',null,15,'fake','[]')$$,
'42501','permission denied for function change_check_in','client cannot inject timer provider payload');
select throws_ok($$select public.gateway_change_check_in(gen_random_uuid(),gen_random_uuid(),'start',null,15,'fake','[]')$$,
'42501','permission denied for function gateway_change_check_in','client cannot impersonate a subject through the gateway');
reset role;
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('b1000000-0000-4000-8000-000000000001','authenticated','authenticated','boundary@example.test','{}','{}',now(),now());
insert into public.profiles(id,display_name) values('b1000000-0000-4000-8000-000000000001','Boundary');
insert into public.trusted_contacts(user_id,name,channel,destination_ciphertext,destination_fingerprint,status,confirmed_at)
values('b1000000-0000-4000-8000-000000000001','Contact','email',repeat('x',48),repeat('f',64),'confirmed',now());
set local role service_role;
select lives_ok($$select public.gateway_change_check_in('b1000000-0000-4000-8000-000000000001',gen_random_uuid(),'start',null,15,'fake',
(select jsonb_agg(jsonb_build_object('hash',encode(extensions.digest(repeat(i::text,43),'sha256'),'hex'),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i))$$,'verified server creates timer with nested ownership checks');
select lives_ok($$select * from public.gateway_create_routed_alert('b1000000-0000-4000-8000-000000000001',gen_random_uuid(),'test','manual','fake',
(select jsonb_agg(jsonb_build_object('token',repeat(i::text,43),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i))$$,'verified server creates routed TEST');
reset role;
select is((select count(*) from public.check_in_timers where user_id='b1000000-0000-4000-8000-000000000001'),1::bigint,'server operation persisted once');
set local role anon;
select lives_ok($$do $loop$ begin for i in 1..120 loop perform public.get_public_event(extensions.digest(repeat('1',43),'sha256')); end loop; end $loop$; $$,'normal polling budget is available');
select throws_ok($$select * from public.get_public_event(extensions.digest(repeat('1',43),'sha256'))$$,'P0001','RATE_LIMITED','excess reads are bounded');
select is(public.acknowledge_public_event(extensions.digest(repeat('1',43),'sha256')),true,'polling does not suppress acknowledgement');
select throws_ok($$select * from public.get_public_event_before_budget(extensions.digest(repeat('1',43),'sha256'))$$,'42501','permission denied for function get_public_event_before_budget','old endpoint cannot bypass budget');
reset role;
select * from finish();
rollback;
