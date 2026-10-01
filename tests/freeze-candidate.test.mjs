import test from 'node:test';import assert from 'node:assert/strict';
import {freezeProblems} from '../scripts/freeze-candidate.mjs';
import {functions} from '../scripts/release-manifest.mjs';
const manifest={commit:'a'.repeat(40),dirty:false,migrations:['supabase/migrations/1.sql']};
const valid=()=>({commit:manifest.commit,reproducedCommit:manifest.commit,environment:'development',publicEnrollment:false,
 gates:Array.from({length:17},(_,i)=>({id:`H${String(i+1).padStart(2,'0')}`,status:'PASS',evidence:[{file:'proof.json',sha256:'b'.repeat(64)}]})),
 functionVersions:Object.fromEntries(functions.map(x=>[x,1])),viewerDeployment:'dpl_fixture',authorityVersion:'authority-fixture',monitorVersion:'monitor-fixture',migration:'1.sql'});
test('freeze rejects incomplete hosted proof and candidate drift',()=>{
 assert.deepEqual(freezeProblems(manifest,valid()),[]);
 const incomplete=valid();incomplete.gates[3].status='BLOCKED';assert.ok(freezeProblems(manifest,incomplete).includes('UNVERIFIED_H04'));
 assert.ok(freezeProblems({...manifest,dirty:true},valid()).includes('CANDIDATE_MISMATCH'));
 const missing=valid();delete missing.functionVersions['user-api'];assert.ok(freezeProblems(manifest,missing).some(x=>x.includes('user-api')));
});
