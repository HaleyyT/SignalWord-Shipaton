import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtempSync,readFileSync,readdirSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {parseServerTiming,runHostedEnvelope} from '../scripts/hosted-load-envelope.mjs';
const fixture={environment:'development',origin:'https://voepalyamwgenceawdvl.supabase.co',signupDisabled:true,publishableKey:'public',senders:Array.from({length:10},(_,i)=>({subject:'sender'+i,token:'private-'+i,key:'key'+i,clientTriggeredAt:'2026-09-29T00:00:00Z',consentConfirmed:true})),readers:Array.from({length:20},(_,i)=>({capability:'private-capability-'+i%10}))};
test('full envelope preserves 40 samples and duplicate identity without private data',async()=>{
 const dir=mkdtempSync(join(tmpdir(),'load-proof-'));let calls=0;
 try{const result=await runHostedEnvelope({fixture,outputPrefix:join(dir,'run'),fetchImpl:async(url,options)=>{calls++;return Response.json(url.includes('/alerts')?{eventId:options.headers['Idempotency-Key']}:{kind:'test'});}});
 assert.equal(calls,40);assert.equal(result.httpPassed,true);assert.equal(result.providerUniquenessVerified,false);
 const records=readdirSync(dir).map(f=>readFileSync(join(dir,f),'utf8')).join('');assert.equal(records.trim().split('\n').length,40);assert.ok(!records.includes('private'));assert.ok(!records.includes('key0'));
 }finally{rmSync(dir,{recursive:true,force:true});}
});
test('one sender repeated ten times and missing consent fail before network',async()=>{
 for(const senders of [Array(10).fill(fixture.senders[0]),fixture.senders.map(s=>({...s,consentConfirmed:false}))])await assert.rejects(runHostedEnvelope({fixture:{...fixture,senders},fetchImpl:()=>{throw Error('NETWORK_MUST_NOT_RUN');}}),/REQUIRED/);
});
test('server timing parser accepts only declared numeric development phases',()=>{
 assert.deepEqual(parseServerTiming('auth_session;dur=10.4, database;dur=3, app;dur=18.2, secret;dur=99, preparation;dur=bad'),{authSessionMs:10.4,databaseMs:3,appMs:18.2});
 assert.deepEqual(parseServerTiming(''),{});
});
