import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {acquireLocalFixtureLock,localContainer} from './local-fixture.mjs';
import {reconcileClone} from './restore-clone-reconcile.mjs';
import {journalDigest} from '../infrastructure/control/service.mjs';
acquireLocalFixtureLock();
const sql=q=>execFileSync('docker',['exec','-i',localContainer,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','postgres'],{input:q,encoding:'utf8'}).trim();
assert.equal(sql('select count(*) from auth.users'),'0','Only an empty disposable local database is allowed');
const target='abcdefghijklmnopqrst';const migration=sql('select max(version) from supabase_migrations.schema_migrations');
const snapshot={state:{quarantined:true,backupAt:new Date().toISOString(),coverageStart:new Date(Date.now()-60000).toISOString(),restoreId:crypto.randomUUID(),version:0},entries:[],digest:await journalDigest([])};
const query=async(project,text)=>{assert.equal(project,target);return JSON.parse(sql(`select coalesce(json_agg(proof),'[]') from (${text}) proof`));};
const jobs=JSON.parse(sql("select coalesce(json_agg(json_build_object('id',jobid,'active',active,'name',jobname)),'[]') from cron.job"));
assert.ok(jobs.every(j=>Number.isInteger(j.id)&&j.name.startsWith('signalword-')),'Unexpected local job');
try {
 for(const job of jobs)sql(`select cron.alter_job(${job.id},active:=false)`);
 const result=await reconcileClone({targetProject:target,expectedMigration:migration,projects:[{id:'voepalyamwgenceawdvl',organization_id:'local-fixture'},{id:target,organization_id:'local-fixture',name:'signalword-dev-restore-local'}],snapshot,readSnapshot:async()=>snapshot,query});
 assert.equal(result.released,false);assert.equal(result.duplicateReplayMatched,true);assert.equal(result.databaseReceiptMatched,true);
 console.log('PASS clone verifier against real local PostgreSQL: isolation queries, duplicate replay, receipt verification, revoked access/schedule checks; never released. NOT managed restore evidence.');
} finally {for(const job of jobs)sql(`select cron.alter_job(${job.id},active:=${job.active?'true':'false'})`);sql(`delete from public.restore_reconciliation_receipts where restore_id='${snapshot.state.restoreId}'::uuid`);}
