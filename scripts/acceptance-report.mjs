import {createHash} from 'node:crypto';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const cases = ['A1','C1','C2','L1','L2'];
const states = ['PASS','FAIL','BLOCKED','NOT_RUN'];
const digest = value => createHash('sha256').update(value).digest('hex');
const safeRef = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
/** Reconstruct an allowlisted report. Raw operator records never reach output. */
export function acceptanceReport(input) {
  if (!/^[a-f0-9]{40}$/.test(input.commit ?? '') || input.environment !== 'development') throw Error('CANDIDATE_IDENTITY_REQUIRED');
  const rows = input.cases ?? [];
  if (new Set(rows.map(x=>x.id)).size !== rows.length) throw Error('DUPLICATE_CASE');
  const result = cases.map(id => {
    const row=rows.find(x=>x.id===id) ?? {status:'NOT_RUN'};
    if (!states.includes(row.status)) throw Error('INVALID_STATUS');
    const evidence=(row.evidenceHashes ?? []).filter(safeRef);
    if (evidence.length !== (row.evidenceHashes ?? []).length) throw Error('INVALID_EVIDENCE_REFERENCE');
    if (row.status==='PASS' && evidence.length===0) throw Error('PASS_REQUIRES_EVIDENCE');
    if (row.latencyMs!=null && (!Number.isFinite(row.latencyMs) || row.latencyMs<0)) throw Error('INVALID_LATENCY');
    return {id,status:row.status,latencyMs:row.latencyMs ?? null,evidenceHashes:evidence,
      defectHashes:(row.defectHashes ?? []).map(x=>{if(!safeRef(x))throw Error('INVALID_DEFECT_REFERENCE');return x;}),
      retestOf:safeRef(row.retestOf)?row.retestOf:null};
  });
  if(rows.some(x=>!cases.includes(x.id)))throw Error('UNKNOWN_CASE');
  let previousPassed=true;
  for(const row of result){if(row.status==='PASS' && !previousPassed)throw Error('PREREQUISITE_NOT_PASSED');previousPassed &&= row.status==='PASS';}
  return {schemaVersion:1,commit:input.commit,environment:'development',app:{version:'1.0',build:'2'},
    sourceDigest:digest(JSON.stringify(input)),cases:result,
    passed:result.filter(x=>x.status==='PASS').length,total:cases.length,
    remaining:result.filter(x=>x.status!=='PASS').map(x=>x.id)};
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [source,destination]=process.argv.slice(2);
  if(!source||!destination)throw Error('INPUT_AND_NEW_OUTPUT_REQUIRED');
  const report=acceptanceReport(JSON.parse(readFileSync(source,'utf8')));
  // Never overwrite a failure report with a later passing retest.
  writeFileSync(destination,JSON.stringify(report,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify({passed:report.passed,total:report.total,remaining:report.remaining}));
}
