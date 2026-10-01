begin;
set local signalword.local_fixture='true';
select no_plan();
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('81000000-0000-4000-8000-000000000001','authenticated','authenticated','network@example.test','{}','{}',now(),now());
insert into public.profiles(id,display_name,routing_policy) values('81000000-0000-4000-8000-000000000001','Network','primary_then_others');
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
select ('82000000-0000-4000-8000-00000000000'||i)::uuid,'81000000-0000-4000-8000-000000000001','Person '||i,'email',repeat(i::text,48),repeat(i::text,64),1,'confirmed',now() from generate_series(1,3) i;
select throws_ok($$insert into public.trusted_contacts(user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version) values('81000000-0000-4000-8000-000000000001','Fourth','email',repeat('d',48),repeat('d',64),1)$$,'23514','CONTACT_LIMIT','fourth contact is rejected');
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is(jsonb_array_length(public.contact_network('81000000-0000-4000-8000-000000000001')->'contacts'),3,'all own contacts recover');
select is((select contact_id from public.get_my_contact('81000000-0000-4000-8000-000000000001')),'82000000-0000-4000-8000-000000000001'::uuid,'old client reads explicit primary');
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select * from public.create_routed_alert('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','real','manual','fake',(select jsonb_agg(jsonb_build_object('token',repeat(i::text,43),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i),null,now())$$,'three-recipient incident accepted');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select * from public.create_routed_alert('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001','real','manual','fake',(select jsonb_agg(jsonb_build_object('token',repeat((i+3)::text,43),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i),null,now())$$,'lost response retry reuses incident');
set local role authenticated;
reset role;
select is((select count(*) from public.alert_events),1::bigint,'duplicate request creates one incident');
select is((select count(*) from public.alert_deliveries),3::bigint,'one initial delivery per recipient');
select is((select count(distinct token_hash) from public.viewer_tokens),3::bigint,'independent capability for each recipient');
select is((select count(*) from public.alert_deliveries where next_attempt_at>now()),2::bigint,'remaining recipients scheduled later');
update public.alert_deliveries set created_at=now()-interval '5 minutes';
select is((public.signalword_delivery_health()->>'oldestQueuedSeconds')::numeric,0::numeric,'intentional escalation delay is not an overdue queue');
select is((select count(*) from public.claim_alert_deliveries('84000000-0000-4000-8000-000000000001',3)),1::bigint,'only primary due now');
select is((select count(*) from public.claim_alert_deliveries('84000000-0000-4000-8000-000000000002',3)),0::bigint,'duplicate worker cannot claim leased primary');
set local role anon;
select is(public.acknowledge_public_event(extensions.digest(repeat('1',43),'sha256')),true,'primary acknowledges');
select ok((select projection ? 'acknowledgedAt' from public.get_public_event(extensions.digest(repeat('1',43),'sha256'))),'primary sees own acknowledgement');
select ok(not (select projection ? 'acknowledgedAt' from public.get_public_event(extensions.digest(repeat('2',43),'sha256'))),'second recipient does not inherit primary acknowledgement');
reset role;
update public.alert_deliveries set next_attempt_at=now() where lease_owner is null;
select is((select count(*) from public.claim_alert_deliveries('84000000-0000-4000-8000-000000000002',3)),2::bigint,'acknowledgement does not cancel escalation');
select is((select count(*) from public.claim_alert_deliveries(gen_random_uuid(),3)),0::bigint,'repeat escalation worker creates no duplicate claim');
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select is(jsonb_array_length(public.recipient_progress('81000000-0000-4000-8000-000000000001',(select id from public.alert_events))),3,'sender recovers all recipient progress');
select public.disable_contact('81000000-0000-4000-8000-000000000001','82000000-0000-4000-8000-000000000002');
reset role;
select is((select count(*) from public.viewer_tokens where revoked_at is not null),1::bigint,'withdrawal revokes only own link');
select is((select last_error_code from public.alert_deliveries where trusted_contact_id='82000000-0000-4000-8000-000000000002'),'CONTACT_WITHDRAWN','withdrawal invalidates delivery');
set local role anon;
select is(public.acknowledge_public_event(extensions.digest(repeat('2',43),'sha256')),false,'withdrawn capability cannot acknowledge');
select is((select count(*) from public.get_public_event(extensions.digest(repeat('2',43),'sha256'))),0::bigint,'withdrawn viewer denied');
reset role;
-- Resolve before a remaining unclaimed delivery starts.
update public.alert_deliveries set lease_owner=null,lease_expires_at=null where trusted_contact_id='82000000-0000-4000-8000-000000000003';
set local role authenticated;
select lives_ok($$select * from public.resolve_alert('81000000-0000-4000-8000-000000000001',(select id from public.alert_events))$$,'sender resolves incident');
reset role;
select is((select last_error_code from public.alert_deliveries where trusted_contact_id='82000000-0000-4000-8000-000000000003' and message_type='initial'),'EVENT_RESOLVED','resolution cancels unclaimed escalation');
select is((select count(*) from public.claim_alert_deliveries(gen_random_uuid(),3)),0::bigint,'resolved incident starts no initial sends');
select is((select count(*) from public.alert_deliveries where message_type='resolved'),1::bigint,'only in-flight primary needs resolution delivery');
-- Cross-user API reads fail closed.
select set_config('request.jwt.claim.sub','85000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select throws_ok($$select public.contact_network('81000000-0000-4000-8000-000000000001')$$,'42501','NOT_AUTHORIZED','network denies another user');
select is(public.recipient_progress('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000001'),'[]'::jsonb,'progress denies another user');
reset role;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
set local role authenticated;
reset role;
select public.prepare_journaled_deletion('81000000-0000-4000-8000-000000000001',extensions.digest('network-deletion','sha256'));
-- SQL fixture: external durability itself is verified by authority integration tests.
select public.journal_mark_durable(id) from public.safety_journal_outbox;
select public.finish_journaled_deletion();
reset role;
select is((select count(*) from public.viewer_tokens),0::bigint,'deletion removes all recipient capabilities');
select is((select count(*) from public.alert_deliveries),0::bigint,'deletion removes all pending and in-flight recipient work');
select * from finish();
rollback;
