import { recordConcurrentSamples } from './acceptance-samples.mjs';
const origin='https://voepalyamwgenceawdvl.supabase.co';
const timingNames={auth_session:'authSessionMs',preparation:'preparationMs',database:'databaseMs',app:'appMs'};

export function parseServerTiming(value) {
 const phases={};
 for(const entry of String(value??'').split(',')) {
   const match=/^\s*([a-z_]+)\s*;\s*dur=([0-9]+(?:\.[0-9]+)?)\s*$/.exec(entry);
   const name=match&&timingNames[match[1]],duration=match&&Number(match[2]);
   if(name&&Number.isFinite(duration)&&duration>=0)phases[name]=duration;
 }
 return phases;
}
/** Credentials/capabilities remain in the private fixture. Only aggregate/sample scalars leave. */
export async function runHostedEnvelope({fixture,outputPrefix,fetchImpl=fetch}) {
 if(fixture.environment!=='development'||fixture.origin!==origin||fixture.signupDisabled!==true)throw Error('CLOSED_DEVELOPMENT_REQUIRED');
 const senders=fixture.senders;
 if(!Array.isArray(senders)||senders.length!==10||new Set(senders.map(s=>s.subject)).size!==10)throw Error('TEN_DISTINCT_SENDERS_REQUIRED');
 if(senders.some(s=>!s.token||!s.key||!s.clientTriggeredAt||s.consentConfirmed!==true))throw Error('CONSENTED_SENDER_FIXTURES_REQUIRED');
 const readers=fixture.readers;
 if(!Array.isArray(readers)||readers.length!==20||new Set(readers.map(r=>r.capability)).size<10||readers.some(r=>!r.capability))throw Error('TWENTY_READS_ACROSS_TEN_CAPABILITIES_REQUIRED');
 const eventIds=new Map();
 const submit=async round=>recordConcurrentSamples({count:10,output:`${outputPrefix}-send-${round}.jsonl`,request:async i=>{
   const s=senders[i];
   const response=await fetchImpl(origin+'/functions/v1/user-api/v2/alerts',{method:'POST',redirect:'error',signal:AbortSignal.timeout(25000),headers:{apikey:fixture.publishableKey,Authorization:'Bearer '+s.token,'Content-Type':'application/json','Idempotency-Key':s.key},body:JSON.stringify({kind:'test',triggerMethod:'manual',clientTriggeredAt:s.clientTriggeredAt})});
   const body=await response.json();
   const previous=eventIds.get(i);
   if(response.ok&&typeof body.eventId==='string'&&!previous)eventIds.set(i,body.eventId);
   return {status:response.status,valid:typeof body.eventId==='string' && (!previous||previous===body.eventId),phases:parseServerTiming(response.headers.get('server-timing'))};
 }});
 const first=await submit('first'), duplicate=await submit('duplicate');
 const reads=await recordConcurrentSamples({count:20,output:`${outputPrefix}-read.jsonl`,request:async i=>{
   const response=await fetchImpl('https://www.signalword.app/v1/public/events/'+encodeURIComponent(readers[i].capability),{redirect:'error',signal:AbortSignal.timeout(25000)});
   const body=await response.json();return {status:response.status,valid:body.kind==='test'};
 }});
 return {first,duplicate,reads,uniqueAcceptedIncidents:new Set(eventIds.values()).size,
   httpPassed:first.successful===10&&duplicate.successful===10&&reads.successful===20&&new Set(eventIds.values()).size===10&&first.p95Ms<=2000&&duplicate.p95Ms<=2000&&reads.p95Ms<=5000,
   providerUniquenessVerified:false,providerLatencyVerified:false};
}
