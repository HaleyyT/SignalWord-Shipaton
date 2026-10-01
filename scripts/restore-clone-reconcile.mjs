import {journalDigest} from '../infrastructure/control/service.mjs';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync,readFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const SOURCE='voepalyamwgenceawdvl';
const CONTROL='https://authority-dev.signalword.app';
// PostgreSQL count values must be explicit; null/missing evidence is not zero.
const verifiedZero=value=>value===0 || value==='0';
export const isolationSQL=`select
 (select count(*) from cron.job where active) as active_jobs,
 (select count(*) from net.http_request_queue) as pending_network,
 (select max(version) from supabase_migrations.schema_migrations) as migration`;
export const safetySQL=`select
 (select count(*) from public.alert_deliveries where status='queued' or last_error_code='OUTCOME_UNKNOWN') as unsafe_alerts,
 (select count(*) from public.contact_verification_deliveries where status='queued' or last_error_code='OUTCOME_UNKNOWN') as unsafe_invitations,
 (select count(*) from public.check_in_timers where state='active') as active_timers,
 (select count(*) from public.viewer_tokens where revoked_at is null) as open_viewers,
 (select count(*) from public.contact_confirmation_tokens) as confirmations,
 (select count(*) from auth.sessions) as sessions,
 (select count(*) from auth.refresh_tokens) as refresh_tokens`;
/** Clone-only replay. NEVER calls /release, changes routing, or enables workers. */
export async function reconcileClone({targetProject,projects,expectedMigration,snapshot,readSnapshot,query,now=Date.now()}) {
 if(!/^[a-z]{20}$/.test(targetProject??'') || targetProject===SOURCE)throw Error('ISOLATED_TARGET_REQUIRED');
 const source=projects.find(x=>x.id===SOURCE),target=projects.find(x=>x.id===targetProject);
 if(!source || !target || target.organization_id!==source.organization_id || !/^signalword-dev-restore-[a-z0-9-]+$/.test(target.name??''))throw Error('APPROVED_CLONE_IDENTITY_REQUIRED');
 if(!/^\d{14}$/.test(expectedMigration??''))throw Error('MIGRATION_REQUIRED');
 const state=snapshot?.state,backup=Date.parse(state?.backupAt),coverage=Date.parse(state?.coverageStart);
 if(state?.quarantined!==true || !Number.isFinite(backup) || !Number.isFinite(coverage) || backup<coverage || backup>now || now-backup>90*86400000 || !/^[a-f0-9-]{36}$/.test(state.restoreId??'') || !Number.isSafeInteger(state.version) || state.version<0 || !Array.isArray(snapshot.entries) || snapshot.digest!==await journalDigest(snapshot.entries))throw Error('COVERED_QUARANTINE_REQUIRED');
 const inspect=async()=>{const [r]=await query(targetProject,isolationSQL);if(!r || !verifiedZero(r.active_jobs) || !verifiedZero(r.pending_network) || r.migration!==expectedMigration)throw Error('CLONE_NOT_ISOLATED');};
 await inspect();
 const entries=JSON.stringify(snapshot.entries).replace(/'/g,"''");
 const proof=`'${state.restoreId}'::uuid,${state.version},'${snapshot.digest}'`;
 for(let i=0;i<2;i++) {
  await query(targetProject,`select public.reconcile_restore_journal(${proof},'${entries}'::jsonb)`);
  const [r]=await query(targetProject,`select public.restore_receipt_matches(${proof}) as matched`);
  if(r?.matched!==true)throw Error('CLONE_RECEIPT_MISMATCH');
 }
 const [safety]=await query(targetProject,safetySQL);
 if(!safety || ['unsafe_alerts','unsafe_invitations','active_timers','open_viewers','confirmations','sessions','refresh_tokens'].some(k=>!verifiedZero(safety[k])))throw Error('CLONE_UNSAFE_AFTER_REPLAY');
 await inspect();
 const latest=await readSnapshot();
 if(latest?.state?.quarantined!==true || latest.state.restoreId!==state.restoreId || latest.state.version!==state.version || latest.digest!==snapshot.digest || latest.digest!==await journalDigest(latest.entries))throw Error('JOURNAL_CHANGED_DURING_REPLAY');
 return {environment:'development',sourceProject:SOURCE,targetProject,journalVersion:state.version,journalDigest:snapshot.digest,duplicateReplayMatched:true,databaseReceiptMatched:true,restoredSchedulesDisabled:true,historicalWorkCancelled:true,allRestoredCapabilitiesRevoked:true,released:false,providerSendsEnabled:false};
}
if(process.argv[1] && resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
 const [configuration,output]=process.argv.slice(2);if(!configuration||!output)throw Error('PRIVATE_CONFIG_AND_NEW_REPORT_REQUIRED');
 const config=JSON.parse(readFileSync(configuration,'utf8'));
 if(config.sourceProject!==SOURCE || config.controlOrigin!==CONTROL)throw Error('DEVELOPMENT_SOURCE_REQUIRED');
 const admin=process.env.SAFETY_CONTROL_ADMIN;if(!admin)throw Error('LOCAL_AUTHORITY_CREDENTIAL_REQUIRED');
 const cli=args=>{try{return JSON.parse(execFileSync('npx',['supabase',...args,'-o','json'],{encoding:'utf8',stdio:['ignore','pipe','pipe'],timeout:60000}));}catch{throw Error('CLONE_CLI_FAILED_NO_RELEASE');}};
 const projects=cli(['projects','list']);
 const query=async(project,sql)=>{
  if(project!==config.targetProject || project===SOURCE)throw Error('TARGET_PIN_FAILED');
  const dir=mkdtempSync(join(tmpdir(),'signalword-clone-'));
  try {const file=join(dir,'query.sql');writeFileSync(file,sql,{mode:0o600});return cli(['db','query','--linked','--project-ref',project,'-f',file]).rows;}
  finally{rmSync(dir,{recursive:true,force:true});}
 };
 const readSnapshot=async()=>{const r=await fetch(CONTROL+'/snapshot',{redirect:'error',signal:AbortSignal.timeout(20000),headers:{Authorization:'Bearer '+admin}});if(!r.ok)throw Error('AUTHORITY_UNAVAILABLE');return r.json();};
 const snapshot=await readSnapshot();
 const result=await reconcileClone({...config,projects,snapshot,readSnapshot,query});
 writeFileSync(output,JSON.stringify(result,null,2)+'\n',{flag:'wx',mode:0o600});console.log(JSON.stringify(result));
}
