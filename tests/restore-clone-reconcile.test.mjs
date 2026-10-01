import test from 'node:test';import assert from 'node:assert/strict';
import {reconcileClone,isolationSQL,safetySQL} from '../scripts/restore-clone-reconcile.mjs';
import {journalDigest} from '../infrastructure/control/service.mjs';
const source='voepalyamwgenceawdvl',target='abcdefghijklmnopqrst';
async function fixture(){const snap={state:{quarantined:true,backupAt:new Date().toISOString(),coverageStart:'2026-01-01',restoreId:'00000000-0000-4000-8000-000000000001',version:0},entries:[],digest:await journalDigest([])};const calls=[];return {targetProject:target,expectedMigration:'20261001040000',projects:[{id:source,organization_id:'dev'},{id:target,organization_id:'dev',name:'signalword-dev-restore-drill'}],snapshot:snap,readSnapshot:async()=>snap,calls,query:async(p,q)=>{calls.push([p,q]);if(q===isolationSQL)return [{active_jobs:0,pending_network:0,migration:'20261001040000'}];if(q===safetySQL)return [{unsafe_alerts:0,unsafe_invitations:0,active_timers:0,open_viewers:0,confirmations:0,sessions:0,refresh_tokens:0}];return [{matched:true}];}};}
test('clone replay repeats receipts and never releases or mutates source',async()=>{const f=await fixture();const r=await reconcileClone(f);assert.equal(r.released,false);assert.equal(r.duplicateReplayMatched,true);assert.equal(f.calls.filter(([,q])=>q.includes('select public.reconcile_restore_journal')).length,2);assert.ok(f.calls.every(([p])=>p===target));});
test('source, wrong organization and invalid migration rejected before queries',async()=>{for(const change of [{targetProject:source},{expectedMigration:'bad'},{projects:[]}]){const f=await fixture();await assert.rejects(()=>reconcileClone({...f,...change}));assert.equal(f.calls.length,0);}});
test('active jobs, pending outbound requests and schema mismatch block replay',async()=>{for(const row of [{active_jobs:1,pending_network:0,migration:'20261001040000'},{active_jobs:0,pending_network:1,migration:'20261001040000'},{active_jobs:0,pending_network:0,migration:'0'}]){const f=await fixture();await assert.rejects(()=>reconcileClone({...f,query:async()=>[row]}),/CLONE_NOT_ISOLATED/);}});
test('stale or uncovered journal fails closed',async()=>{const f=await fixture();await assert.rejects(()=>reconcileClone({...f,snapshot:{...f.snapshot,state:{...f.snapshot.state,coverageStart:'2099-01-01'}}}),/COVERED/);await assert.rejects(()=>reconcileClone({...f,readSnapshot:async()=>({...f.snapshot,state:{...f.snapshot.state,version:1}})}),/JOURNAL_CHANGED/);});
test('missing receipt and unsafe historical work block success',async()=>{for(const unsafe of [false,true]){const f=await fixture();const old=f.query;await assert.rejects(()=>reconcileClone({...f,query:async(p,q)=>q.includes('restore_receipt_matches')&&!unsafe?[{matched:false}]:q===safetySQL&&unsafe?[{unsafe_alerts:1}]:old(p,q)}));}});

test('null or boolean counts cannot masquerade as verified zero',async()=>{
 for(const value of [null,false,'',undefined]) {
  const f=await fixture();const old=f.query;
  await assert.rejects(()=>reconcileClone({...f,query:async(p,q)=>q===isolationSQL?[{active_jobs:value,pending_network:0,migration:'20261001040000'}]:old(p,q)}),/CLONE_NOT_ISOLATED/);
  await assert.rejects(()=>reconcileClone({...f,query:async(p,q)=>q===safetySQL?[{unsafe_alerts:value,unsafe_invitations:0,active_timers:0,open_viewers:0,confirmations:0,sessions:0,refresh_tokens:0}]:old(p,q)}),/CLONE_UNSAFE_AFTER_REPLAY/);
 }
});
