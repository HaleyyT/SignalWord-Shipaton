begin;
set local signalword.local_fixture='true';
select no_plan();
select is(has_function_privilege('authenticated','public.delete_my_account(uuid,bytea)','EXECUTE'),false,'old receipt deletion cannot bypass journal');
select is(has_function_privilege('authenticated','public.prepare_journaled_deletion(uuid,bytea)','EXECUTE'),false,'only verified backend can prepare deletion');
select is(has_function_privilege('authenticated','public.reconcile_restore_journal(uuid,bigint,text,jsonb)','EXECUTE'),false,'client cannot reopen restored state');
set local signalword.local_fixture='false';
select throws_ok($$select public.require_safety_authority()$$,'P0001','SAFETY_AUTHORITY_UNAVAILABLE','missing authority configuration fails closed');
set local signalword.local_fixture='true';
insert into auth.users(id,aud,role,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('b1000000-0000-4000-8000-000000000001','authenticated','authenticated','{}','{}',now(),now());
insert into public.profiles(id,display_name) values('b1000000-0000-4000-8000-000000000001','Restore fixture');
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at)
values('b2000000-0000-4000-8000-000000000001','b1000000-0000-4000-8000-000000000001','Fixture','email',repeat('a',48),repeat('a',64),1,'confirmed',now());
select public.prepare_journaled_deletion('b1000000-0000-4000-8000-000000000001',extensions.digest('restore-receipt','sha256'));
select is((select count(*) from public.safety_journal_outbox where user_id='b1000000-0000-4000-8000-000000000001'),2::bigint,'deletion journals account and consent revocation');
select public.finish_journaled_deletion();
select is((select count(*) from auth.users),1::bigint,'interrupted journaling preserves resumable account');
select throws_ok($$update public.trusted_contacts set status='confirmed',confirmed_at=now() where id='b2000000-0000-4000-8000-000000000001'$$,'P0001','ACCOUNT_DELETION_PENDING','pending deletion cannot restore consent');
select public.journal_mark_durable(id) from public.safety_journal_outbox;
select public.finish_journaled_deletion();
select public.finish_journaled_deletion();
select is((select count(*) from auth.users),0::bigint,'durable deletion is idempotent');
-- Simulate the old account row from a backup. Full backup/restore is a separate drill.
insert into auth.users(id,aud,role,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('b1000000-0000-4000-8000-000000000001','authenticated','authenticated','{}','{}',now(),now());
select public.reconcile_restore_journal('b3000000-0000-4000-8000-000000000001',2,repeat('a',64),
 '[{"input":{"userId":"b1000000-0000-4000-8000-000000000001","kind":"delete"}}]');
select is((select count(*) from auth.users),0::bigint,'replay removes restored deleted identity');
select public.reconcile_restore_journal('b3000000-0000-4000-8000-000000000001',2,repeat('a',64),
 '[{"input":{"userId":"b1000000-0000-4000-8000-000000000001","kind":"delete"}}]');
select is((select count(*) from public.restore_reconciliation_receipts),1::bigint,'duplicate replay has one receipt');
-- Later explicit consent survives replay of an older withdrawn generation.
insert into auth.users(id,aud,role,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
values('b1000000-0000-4000-8000-000000000002','authenticated','authenticated','{}','{}',now(),now());
insert into public.profiles(id,display_name) values('b1000000-0000-4000-8000-000000000002','Consent fixture');
insert into public.trusted_contacts(id,user_id,name,channel,destination_ciphertext,destination_fingerprint,destination_key_version,status,confirmed_at,consent_generation)
values('b2000000-0000-4000-8000-000000000002','b1000000-0000-4000-8000-000000000002','Fixture','email',repeat('b',48),repeat('b',64),1,'confirmed',now(),2);
select public.reconcile_restore_journal('b3000000-0000-4000-8000-000000000002',3,repeat('b',64),
 '[{"input":{"userId":"b1000000-0000-4000-8000-000000000002","contactId":"b2000000-0000-4000-8000-000000000002","kind":"withdraw","generation":1}}]');
select is((select status from public.trusted_contacts where id='b2000000-0000-4000-8000-000000000002'),'confirmed','newer consent is retained');
insert into public.contact_verification_deliveries(trusted_contact_id,provider,provider_idempotency_key,payload_ciphertext,payload_key_version,attempt_count)
values('b2000000-0000-4000-8000-000000000002','resend','restore-unknown','fixture',1,1);
select throws_ok($$select public.reconcile_restore_journal('b3000000-0000-4000-8000-000000000003',4,repeat('c',64),'[]')$$,'P0001','RESTORE_PROVIDER_RECONCILIATION_REQUIRED','attempted historical delivery prevents reopening');
select is(public.restore_receipt_matches('b3000000-0000-4000-8000-000000000003',4,repeat('c',64)),false,'blocked replay cannot manufacture a receipt');
-- Model a verified provider outcome before retrying reconciliation.
update public.contact_verification_deliveries set status='delivered',completed_at=now(),last_error_code=null where provider_idempotency_key='restore-unknown';
select public.reconcile_restore_journal('b3000000-0000-4000-8000-000000000003',4,repeat('c',64),
 '[{"input":{"userId":"b1000000-0000-4000-8000-000000000002","contactId":"b2000000-0000-4000-8000-000000000002","kind":"withdraw","generation":2}}]');
select is((select status from public.trusted_contacts where id='b2000000-0000-4000-8000-000000000002'),'disabled','matching restored consent is revoked');
select is(public.restore_receipt_matches('b3000000-0000-4000-8000-000000000003',4,repeat('c',64)),true,'settled replay records matching proof');
select is(public.restore_receipt_matches('b3000000-0000-4000-8000-000000000003',3,repeat('c',64)),false,'stale proof cannot reopen');
select * from finish();
rollback;
