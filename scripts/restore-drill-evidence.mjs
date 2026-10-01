import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
/** Offline measurement only. Does not purchase, restore, release or handle credentials. */
export function measureRestore(input) {
  if (input.sourceProject !== 'voepalyamwgenceawdvl' || !/^[a-z]{20}$/.test(input.targetProject ?? '') || input.targetProject === input.sourceProject) throw Error('ISOLATED_DEVELOPMENT_TARGET_REQUIRED');
  const timestamp = key => { const value = Date.parse(input[key]); if (!Number.isFinite(value)) throw Error('TIMESTAMP_REQUIRED:'+key); return value; };
  const start=timestamp('outageStartedAt'), marker=timestamp('latestRecoveredAcknowledgedAt'), ready=timestamp('safeServiceReadyAt');
  if (marker>start || ready<start) throw Error('TIMESTAMP_ORDER_INVALID');
  const required=['sourceQuarantined','restoredSchedulesDisabled','noPendingNetworkRequests','independentJournalCovered','duplicateReplayMatched','databaseReceiptMatched','deletedAccessDenied','withdrawnAccessDenied','historicalWorkCancelled','providerOutcomesReconciled','noCloneProviderSends','routingIsolated'];
  const missing=required.filter(key=>input[key]!==true);
  const rpoSeconds=(start-marker)/1000, rtoSeconds=(ready-start)/1000;
  return {environment:'development',sourceProject:input.sourceProject,targetProject:input.targetProject,rpoSeconds,rtoSeconds,missing,
    passed:missing.length===0 && rpoSeconds<=900 && rtoSeconds<=3600};
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  const [source,output]=process.argv.slice(2); if(!source||!output)throw Error('INPUT_AND_NEW_OUTPUT_REQUIRED');
  const result=measureRestore(JSON.parse(readFileSync(source,'utf8')));
  writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});
  console.log(JSON.stringify(result)); if(!result.passed)process.exitCode=1;
}
