begin;
set local signalword.local_fixture='true';
select no_plan();
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('a1000000-0000-4000-8000-000000000001','authenticated','authenticated','timer@example.test','{}','{}',now(),now());
insert into public.profiles(id,display_name) values('a1000000-0000-4000-8000-000000000001','Timer');
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
values('a2000000-0000-4000-8000-000000000001','a1000000-0000-4000-8000-000000000001','Primary','email',repeat('a',48),repeat('a',64),1,'confirmed',now());
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is(public.recover_check_in('a1000000-0000-4000-8000-000000000001'),null::jsonb,'no active timer is inferred before acceptance');
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','start',null,15,'fake',(select jsonb_agg(jsonb_build_object('hash',encode(extensions.digest(repeat(i::text,43),'sha256'),'hex'),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i))$$,'server accepts 15 minute timer');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','start',null,15,'fake','[]')$$,'retry recovers accepted operation before validating unused payloads');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select throws_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','start',null,30,'fake','[]')$$,'P0001','IDEMPOTENCY_CONFLICT','same operation cannot change duration');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select throws_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001',gen_random_uuid(),'start',null,15,'fake','[]')$$,'P0001','TIMER_ALREADY_ACTIVE','one active timer enforced');
set local role authenticated;
reset role;
select is((select count(*) from public.check_in_timers),1::bigint,'retry creates only one timer');
select ok((select deadline>=created_at+interval '15 minutes' and deadline<created_at+interval '16 minutes' from public.check_in_timers),'deadline owned by server');
select is((select grace_ends_at-deadline from public.check_in_timers),interval '1 minute','one minute grace');
select id as timer_id from public.check_in_timers \gset
create temp table original_deadline as select deadline from public.check_in_timers;
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select public.change_check_in('a1000000-0000-4000-8000-000000000001',gen_random_uuid(),'extend',:'timer_id',30);
set local role authenticated;
reset role;
select is((select t.deadline-o.deadline from public.check_in_timers t cross join original_deadline o),interval '30 minutes','extend adds time rather than shortening a timer');
select is(public.sweep_check_ins(),0,'unexpired timer does not escalate');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select is(public.change_check_in('a1000000-0000-4000-8000-000000000001',gen_random_uuid(),'check_in',:'timer_id')->>'state','checked_in','explicit check-in stops timer');
set local role authenticated;
reset role;
update public.check_in_timers set deadline=now()-interval '2 minutes',grace_ends_at=now()-interval '1 minute';
select is(public.sweep_check_ins(),0,'completed timer never escalates even after deadline');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000002','start',null,30,'fake',(select jsonb_agg(jsonb_build_object('hash',encode(extensions.digest(repeat(i::text,43),'sha256'),'hex'),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i));
set local role authenticated;
reset role;
update public.check_in_timers set deadline=now()-interval '10 minutes',grace_ends_at=now()-interval '9 minutes' where state='active';
select id as late_id from public.check_in_timers where state='active' \gset
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select is(public.change_check_in('a1000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel',:'late_id')->>'state','escalated','late cancellation reconciles expiry and requires explicit alert resolution');
set local role authenticated;
reset role;
select is((select count(*) from public.alert_events where cause='missed_check_in'),1::bigint,'missed check-in creates exactly one incident');
select is((select count(*) from public.alert_deliveries),1::bigint,'one initial recipient message');
select is(public.sweep_check_ins(),0,'duplicate sweeper cannot create another incident');
select is((select count(*) from public.alert_events),1::bigint,'delayed worker and API cannot duplicate incident');
select is((select cause from public.claim_alert_deliveries(gen_random_uuid(),1)),'missed_check_in','delivery worker receives honest cause');
set local role anon;
select is((select projection->>'cause' from public.get_public_event(extensions.digest(repeat('1',43),'sha256'))),'missed_check_in','recipient sees missed-check-in cause');
reset role;
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000003','start',null,60,'fake',(select jsonb_agg(jsonb_build_object('hash',repeat((i+3)::text,64),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i));
set local role authenticated;
reset role;
update public.check_in_timers set deadline=now()-interval '2 minutes',grace_ends_at=now()-interval '1 minute' where state='active';
select is(public.sweep_check_ins(),1,'app-closed server sweep expires due timer');
select is((select count(*) from public.alert_events),1::bigint,'existing REAL incident is reused');
select is((select count(*) from public.alert_deliveries),1::bigint,'existing REAL incident suppresses duplicate contact traffic');
select is((select count(distinct incident_id) from public.check_in_timers where state='escalated'),1::bigint,'both missed timers reference same active REAL incident');
select set_config('request.jwt.claim.sub','a9000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is(public.recover_check_in('a1000000-0000-4000-8000-000000000001'),null::jsonb,'timer recovery does not cross users');
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select throws_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001',gen_random_uuid(),'cancel',gen_random_uuid())$$,'42501','NOT_AUTHORIZED','timer mutations do not cross users');
set local role authenticated;
reset role;
select public.purge_check_ins();
select is((select count(*) from public.check_in_timers where recipient_payloads<>'[]'::jsonb),0::bigint,'ended timers discard unused encrypted capabilities');
update public.check_in_timers set updated_at=now()-interval '25 hours';
select public.purge_check_ins();
select is((select count(*) from public.check_in_timers),0::bigint,'ended timer details expire after retention window');
select set_config('request.jwt.claim.sub','a1000000-0000-4000-8000-000000000001',true);
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select throws_ok($$select public.change_check_in('a1000000-0000-4000-8000-000000000001','a3000000-0000-4000-8000-000000000001','start',null,15,'fake','[]')$$,'P0001','IDEMPOTENCY_EXPIRED','retired operation cannot accidentally arm a new timer');
set local role authenticated;
reset role;
select public.prepare_journaled_deletion('a1000000-0000-4000-8000-000000000001',extensions.digest('timer-delete','sha256'));
-- SQL fixture: external durability itself is verified by authority integration tests.
select public.journal_mark_durable(id) from public.safety_journal_outbox;
select public.finish_journaled_deletion();
reset role;
select is((select count(*) from public.check_in_timers),0::bigint,'deletion cancels and removes timers');
select is((select count(*) from public.check_in_operations),0::bigint,'deletion removes timer command ledger');
select * from finish();
rollback;
