begin;
set local signalword.local_fixture='true';
select no_plan();
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('71000000-0000-4000-8000-000000000001','authenticated','authenticated','recovery@example.test','{}','{}',now(),now());
insert into public.profiles values('71000000-0000-4000-8000-000000000001','Recovery User',now(),null);
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
values('72000000-0000-4000-8000-000000000002','71000000-0000-4000-8000-000000000001','Trusted','email',repeat('d',48),repeat('f',64),1,'confirmed',now());
set local role authenticated;
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
select is(public.signalword_profile('71000000-0000-4000-8000-000000000001','My name')->>'displayName','My name','sender name can be set');
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select * from public.create_or_reuse_alert('71000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000003','test','vocalShortcut',repeat('v',43),'resend',repeat('p',48),1,null,now()-interval '3 minutes')$$,'new client creates test with original trigger time');
set local role authenticated;
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select lives_ok($$select * from public.create_or_reuse_alert('71000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000004','test','vocalShortcut',repeat('w',43),'resend',repeat('p',48),1,null)$$,'old client signature stays compatible');
set local role authenticated;
select is(jsonb_array_length(public.recover_alerts('71000000-0000-4000-8000-000000000001','73000000-0000-4000-8000-000000000004')),1,'cooldown aliases recover their original event');
reset role;
select is((select count(*) from public.alert_events),1::bigint,'cooldown alias never creates another event');
set local role anon;
select is(public.acknowledge_public_event(extensions.digest(repeat('v',43),'sha256')),true,'recipient explicitly acknowledges');
select is(public.acknowledge_public_event(extensions.digest(repeat('v',43),'sha256')),true,'acknowledgement is idempotent');
select ok((select projection ? 'acknowledgedAt' from public.get_public_event(extensions.digest(repeat('v',43),'sha256'))),'public projection includes acknowledgement');
select is(public.acknowledge_public_event(extensions.digest('unknown','sha256')),false,'unknown capability cannot acknowledge');
reset role;
select set_config('request.jwt.claim.sub','74000000-0000-4000-8000-000000000004',true);
set local role authenticated;
select is(public.recover_alerts('71000000-0000-4000-8000-000000000001'),'[]'::jsonb,'recovery does not cross users');
select throws_ok($$select public.signalword_profile('71000000-0000-4000-8000-000000000001','attacker')$$,'42501','NOT_AUTHORIZED','profile updates do not cross users');
reset role;
update public.alert_deliveries set attempt_count=max_attempts,lease_owner=gen_random_uuid(),lease_expires_at=now()-interval '1 second';
select lives_ok('select public.recover_expired_delivery_leases()','final-attempt crash is recovered');
select is((select last_error_code from public.alert_deliveries),'OUTCOME_UNKNOWN','uncertain provider outcome remains explicitly unknown');
select is((select status from public.alert_deliveries),'failed','exhausted work cannot stay queued forever');
update public.alert_deliveries set status='queued',attempt_count=1,lease_owner=gen_random_uuid(),lease_expires_at=now()-interval '1 second',last_error_code=null,completed_at=null;
select is((select count(*) from public.claim_alert_deliveries(gen_random_uuid(),1)),0::bigint,'expired uncertain lease cannot be claimed again');
select public.recover_expired_delivery_leases();
select is((select last_error_code from public.alert_deliveries),'OUTCOME_UNKNOWN','first-attempt crash is quarantined');
select set_config('request.jwt.claim.sub','71000000-0000-4000-8000-000000000001',true);
set local role authenticated;
select lives_ok($$select public.disable_contact('71000000-0000-4000-8000-000000000001','72000000-0000-4000-8000-000000000002')$$,'owner can withdraw contact');
reset role;
set local role anon;
select is(public.acknowledge_public_event(extensions.digest(repeat('v',43),'sha256')),false,'withdrawal revokes acknowledgement capability');
reset role;
-- An early provider receipt is applied when the worker finally records its message ID.
insert into public.contact_verification_deliveries(id,trusted_contact_id,provider,provider_idempotency_key,payload_ciphertext,payload_key_version)
values('75000000-0000-4000-8000-000000000005','72000000-0000-4000-8000-000000000002','resend','contact/early/verification',repeat('c',48),1);
select public.apply_resend_webhook('early-receipt','early-message','delivered');
select * from public.claim_contact_verification_deliveries('76000000-0000-4000-8000-000000000006',1);
select is(public.finish_contact_verification_delivery('75000000-0000-4000-8000-000000000005','76000000-0000-4000-8000-000000000006',true,'early-message',null,true),true,'worker completes after early receipt');
select is((select status from public.contact_verification_deliveries where id='75000000-0000-4000-8000-000000000005'),'delivered','early delivery receipt is reconciled');
select public.apply_resend_webhook('later-failure','early-message','bounced');
select public.apply_resend_webhook('late-delivered','early-message','delivered');
select is((select status from public.contact_verification_deliveries where id='75000000-0000-4000-8000-000000000005'),'failed','late delivery callback cannot erase a known bounce');
select * from finish();
rollback;
