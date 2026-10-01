import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {resolve,dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {releaseManifest,functions} from './release-manifest.mjs';
export function freezeProblems(manifest, acceptance) {
 const problems=[];
 if(manifest.dirty || acceptance.commit!==manifest.commit)problems.push('CANDIDATE_MISMATCH');
 if(acceptance.environment!=='development' || acceptance.publicEnrollment!==false)problems.push('ENVIRONMENT_NOT_CLOSED_DEVELOPMENT');
 const gates=acceptance.gates ?? [];
 for(let i=1;i<=17;i++){
  const id=`H${String(i).padStart(2,'0')}`;const matches=gates.filter(g=>g.id===id);
  if(matches.length!==1||matches[0].status!=='PASS'||!Array.isArray(matches[0].evidence)||!matches[0].evidence.length)problems.push(`UNVERIFIED_${id}`);
 }
 if(gates.length!==17)problems.push('GATE_COUNT_MISMATCH');
 if(acceptance.reproducedCommit!==manifest.commit)problems.push('CLEAN_BUILD_NOT_REPRODUCED');
 for(const name of functions)if(!Number.isInteger(acceptance.functionVersions?.[name])||acceptance.functionVersions[name]<1)problems.push(`FUNCTION_VERSION_MISSING:${name}`);
 for(const name of ['viewerDeployment','authorityVersion','monitorVersion'])if(!/^[A-Za-z0-9_-]{8,100}$/.test(acceptance[name]??''))problems.push(`DEPLOYMENT_VERSION_MISSING:${name}`);
 if(acceptance.migration!==manifest.migrations.at(-1)?.split('/').at(-1))problems.push('MIGRATION_MISMATCH');
 return problems;
}
if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
 const [source,output]=process.argv.slice(2);if(!source||!output)throw Error('ACCEPTANCE_INPUT_AND_NEW_OUTPUT_REQUIRED');
 const root=fileURLToPath(new URL('..',import.meta.url));
 const manifest=releaseManifest(root,JSON.parse(readFileSync(resolve(root,'config/development.release.json'))));
 const acceptance=JSON.parse(readFileSync(source));
 const problems=freezeProblems(manifest,acceptance);if(problems.length)throw Error(problems.join('\n'));
 // Verify every referenced redacted evidence file, not just a PASS label.
 for(const gate of acceptance.gates)for(const ref of gate.evidence){
  if(!/^[a-f0-9]{64}$/.test(ref.sha256??'') || typeof ref.file!=='string')throw Error('INVALID_EVIDENCE_REFERENCE');
  const path=resolve(dirname(resolve(source)),ref.file);
  const hash=createHash('sha256').update(readFileSync(path)).digest('hex');
  if(hash!==ref.sha256)throw Error('EVIDENCE_DIGEST_MISMATCH');
 }
 const safeInventory={functionVersions:acceptance.functionVersions,viewerDeployment:acceptance.viewerDeployment,
 authorityVersion:acceptance.authorityVersion,monitorVersion:acceptance.monitorVersion,migration:acceptance.migration};
 writeFileSync(output,JSON.stringify({...manifest,hosted:safeInventory,acceptanceDigest:createHash('sha256').update(readFileSync(source)).digest('hex'),frozen:true},null,2)+'\n',{flag:'wx',mode:0o600});
 console.log('Frozen manifest written; signing/device acceptance remains separate.');
}
