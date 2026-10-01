-- Development-only database acceptance. Run via the pinned project command in
-- the release runbook. Every fixture and outbox row is rolled back: background
-- workers cannot see uncommitted rows, and no provider is called by this script.
-- This exercises deployed SQL/RLS, not human consent or HTTP/provider delivery.
begin;
set local statement_timeout = '30s';
do $$ begin
 if exists(select 1 from auth.users) then raise exception 'EMPTY_DEVELOPMENT_REQUIRED'; end if;
 perform public.require_safety_authority();
end $$;
create function pg_temp.expect(ok boolean, label text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'HOSTED_CONTACT_PROOF_FAILED: %', label; end if; end $$;
insert into auth.users(id,raw_user_meta_data) values
 ('e9100000-0000-4000-8000-000000000001','{"signalword_client":true}'),
 ('e9100000-0000-4000-8000-000000000002','{"signalword_client":true}');
select set_config('request.jwt.claims',jsonb_build_object('sub','e9100000-0000-4000-8000-000000000001','role','service_role','iat',extract(epoch from now())::bigint)::text,true);
set local role service_role;
do $$ begin
 for i in 1..3 loop
  perform public.save_network_contact(null,'e9100000-0000-4000-8000-000000000001','Proof '||i,'email',repeat(i::text,48),repeat(i::text,64),1,extensions.digest('proof-consent-'||i,'sha256'),repeat(i::text,48),1,'fake');
 end loop;
 -- A lost response must not duplicate an invitation.
 perform public.save_network_contact(null,'e9100000-0000-4000-8000-000000000001','Proof 1','email',repeat('1',48),repeat('1',64),1,extensions.digest('unused-retry-token','sha256'),repeat('1',48),1,'fake');
end $$;
reset role;
select pg_temp.expect((select count(*)=3 from public.trusted_contacts),'three contacts');
select pg_temp.expect((select count(*)=3 from public.contact_verification_deliveries),'idempotent invitations');
select pg_temp.expect((select count(*)=0 from public.trusted_contacts where status='confirmed'),'invitation is not consent');
set local role anon;
select pg_temp.expect(not public.confirm_contact(extensions.digest('unissued-proof','sha256')),'unissued consent denied');
select pg_temp.expect(public.confirm_contact(extensions.digest('proof-consent-1','sha256')),'first consent');
reset role;
select pg_temp.expect((select count(*)=1 from public.trusted_contacts where status='confirmed'),'consent is per recipient');
set local role anon;
select pg_temp.expect(public.confirm_contact(extensions.digest('proof-consent-2','sha256')),'second consent');
select pg_temp.expect(public.confirm_contact(extensions.digest('proof-consent-3','sha256')),'third consent');
reset role;
select set_config('request.jwt.claims',jsonb_build_object('sub','e9100000-0000-4000-8000-000000000001','role','authenticated','iat',extract(epoch from now())::bigint)::text,true);
set local role authenticated;
select pg_temp.expect(not has_function_privilege(current_user,'public.save_network_contact(uuid,uuid,text,text,text,text,integer,bytea,text,integer,text)','execute'),'client cannot mint consent');
select pg_temp.expect(jsonb_array_length(public.contact_network('e9100000-0000-4000-8000-000000000001',null,'primary_then_others')->'contacts')=3,'owner network');
reset role;
select * from public.create_routed_alert('e9100000-0000-4000-8000-000000000001','e9200000-0000-4000-8000-000000000001','test','manual','fake',(select jsonb_agg(jsonb_build_object('token',repeat(i::text,43),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i),null,now());
select * from public.create_routed_alert('e9100000-0000-4000-8000-000000000001','e9200000-0000-4000-8000-000000000001','test','manual','fake',(select jsonb_agg(jsonb_build_object('token',repeat((i+3)::text,43),'ciphertext',repeat(i::text,48),'keyVersion',1)) from generate_series(1,3)i),null,now());
select pg_temp.expect((select count(*)=1 from public.alert_events),'idempotent incident');
select pg_temp.expect((select count(*)=0 from public.alert_events where kind='real'),'TEST remains TEST');
select pg_temp.expect((select count(*)=3 and count(distinct token_hash)=3 from public.viewer_tokens),'separate recipient capabilities');
select pg_temp.expect((select count(*)=2 from public.alert_deliveries where next_attempt_at>now()),'two delayed recipients');
set local role anon;
select pg_temp.expect(public.acknowledge_public_event(extensions.digest(repeat('1',43),'sha256')),'primary acknowledgement');
select pg_temp.expect(not (select projection ? 'acknowledgedAt' from public.get_public_event(extensions.digest(repeat('2',43),'sha256'))),'acknowledgement isolation');
select pg_temp.expect(public.withdraw_contact(extensions.digest('proof-consent-2','sha256')),'recipient withdrawal');
select pg_temp.expect(public.withdraw_contact(extensions.digest('proof-consent-2','sha256')),'withdrawal retry');
select pg_temp.expect(not public.acknowledge_public_event(extensions.digest(repeat('2',43),'sha256')),'withdrawn acknowledgement denied');
select pg_temp.expect((select count(*)=0 from public.get_public_event(extensions.digest(repeat('2',43),'sha256'))),'withdrawn capability denied');
reset role;
select pg_temp.expect((select count(*)=0 from public.alert_deliveries where trusted_contact_id=(select id from public.trusted_contacts where name='Proof 2') and status='QUEUED'),'withdrawal cancels unclaimed work');
select set_config('request.jwt.claims',jsonb_build_object('sub','e9100000-0000-4000-8000-000000000002','role','authenticated','iat',extract(epoch from now())::bigint)::text,true);
set local role authenticated;
select pg_temp.expect((select count(*)=0 from public.trusted_contacts),'cross-user contacts denied');
select pg_temp.expect((select count(*)=0 from public.alert_events),'cross-user incidents denied');
reset role;
rollback;
select jsonb_build_object('checks',23,'result','passed','persisted_users',(select count(*) from auth.users),'persisted_contacts',(select count(*) from public.trusted_contacts),'persisted_deliveries',(select count(*) from public.alert_deliveries)) as evidence;
