import test from 'node:test';
import assert from 'node:assert/strict';
import {acceptanceReport} from '../scripts/acceptance-report.mjs';
const base={commit:'a'.repeat(40),environment:'development'};
test('reports omit private fields and preserve failure status',()=>{
 const value=acceptanceReport({...base,email:'private@example.com',token:'secret',cases:[{id:'A1',status:'FAIL',body:'private phrase',latencyMs:10}]});
 assert.equal(value.cases[0].status,'FAIL');assert.equal(value.remaining.length,5);
 assert.doesNotMatch(JSON.stringify(value),/private|secret|example/);
});
test('passes require evidence, sequence and safe references',()=>{
 assert.throws(()=>acceptanceReport({...base,cases:[{id:'A1',status:'PASS'}]}));
 assert.throws(()=>acceptanceReport({...base,cases:[{id:'C1',status:'PASS',evidenceHashes:['b'.repeat(64)]}]}));
 assert.throws(()=>acceptanceReport({...base,cases:[{id:'A1',status:'FAIL',evidenceHashes:['https://private/token']}]}));
 assert.equal(acceptanceReport({...base,cases:[{id:'A1',status:'PASS',evidenceHashes:['b'.repeat(64)]}]}).passed,1);
});
