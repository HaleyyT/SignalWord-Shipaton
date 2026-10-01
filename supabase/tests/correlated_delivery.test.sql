begin;
set local signalword.local_fixture='true';
select no_plan();
insert into auth.users(id,aud,role,email,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('81000000-0000-4000-8000-000000000001','authenticated','authenticated','correlation@example.test','{}','{}',now(),now());
insert into public.profiles values('81000000-0000-4000-8000-000000000001','Correlation User',now(),null);
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
values('82000000-0000-4000-8000-000000000002','81000000-0000-4000-8000-000000000001','Trusted','email',repeat('d',48),repeat('f',64),1,'confirmed',now());
set local role authenticated;
select set_config('request.jwt.claim.sub','81000000-0000-4000-8000-000000000001',true);
-- Exercise internal state transitions; direct-client denial is tested separately.
reset role;
select * from public.create_or_reuse_alert('81000000-0000-4000-8000-000000000001','83000000-0000-4000-8000-000000000003','test','manual',repeat('t',43),'resend',repeat('p',48),1,null,now());
set local role authenticated;
reset role;
select * from public.claim_alert_deliveries('84000000-0000-4000-8000-000000000004',1);
update public.alert_deliveries set status='failed',completed_at=now(),last_error_code='OUTCOME_UNKNOWN',lease_owner=null,lease_expires_at=null;
select public.reconcile_resend_webhook('signed-receipt','provider-correlated','delivered',
 (select encode(extensions.digest(provider_idempotency_key,'sha256'),'hex') from public.alert_deliveries limit 1));
select is((select status from public.alert_deliveries limit 1),'delivered','lost response reconciles from signed provider receipt without a resend');
select is((select provider_message_id from public.alert_deliveries limit 1),'provider-correlated','receipt attaches missing provider ID');
select is((select attempt_count from public.alert_deliveries limit 1),1,'reconciliation does not create another send attempt');
select is(public.reconcile_resend_webhook('signed-receipt','provider-correlated','delivered',null),false,'duplicate receipt is idempotent');
select throws_ok($$select public.reconcile_resend_webhook('signed-receipt','different-message','sent',repeat('a',64))$$,'22023','CONFLICTING_WEBHOOK_RECEIPT','conflicting replay cannot bind another message');
select public.reconcile_resend_webhook('bounce-receipt','provider-correlated','bounced',null);
select public.reconcile_resend_webhook('late-receipt','provider-correlated','delivered',null);
select is((select status from public.alert_deliveries limit 1),'failed','late delivered receipt cannot erase a bounce');
select is((select last_error_code from public.alert_deliveries limit 1),'BOUNCED','known failure stays visible');
set local role authenticated;
select throws_ok($$select public.reconcile_resend_webhook('spoof','spoof','sent',null)$$,'42501',null,'authenticated clients cannot spoof provider reconciliation');
reset role;
insert into public.contact_verification_deliveries(id,trusted_contact_id,provider,provider_idempotency_key,payload_ciphertext,payload_key_version)
values('85000000-0000-4000-8000-000000000005','82000000-0000-4000-8000-000000000002','resend','contact/correlated/verification',repeat('c',48),1);
select * from public.claim_contact_verification_deliveries('84000000-0000-4000-8000-000000000004',1);
select public.reconcile_resend_webhook('unrelated','unrelated-message','sent',repeat('a',64));
select is((select provider_message_id from public.contact_verification_deliveries limit 1),null::text,'unmatched callback cannot bind an in-flight invitation');
select public.reconcile_resend_webhook('early-contact','contact-message','sent',encode(extensions.digest('contact/correlated/verification','sha256'),'hex'));
select is((select status from public.contact_verification_deliveries limit 1),'sent','early correlated contact callback confirms provider acceptance');
select is(public.finish_contact_verification_delivery('85000000-0000-4000-8000-000000000005','84000000-0000-4000-8000-000000000004',false,null,'OUTCOME_UNKNOWN',false),false,'late worker failure cannot overwrite correlated provider evidence');
select is((select status from public.contact_verification_deliveries limit 1),'sent','late worker failure leaves acceptance intact');
select ok(public.signalword_operational_health() ? 'dispatchConfigured','operator readiness reports missing Vault configuration without exposing secrets');
select is(jsonb_array_length(public.signalword_operational_health()->'schedules'),3,'all required schedules appear in operational evidence');
set local role authenticated;
select throws_ok($$select public.signalword_operational_health()$$,'42501',null,'operational health is not exposed to app users');
reset role;
select * from finish();
rollback;
