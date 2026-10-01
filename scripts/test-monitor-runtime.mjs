import {spawn} from 'node:child_process';
import {mkdtempSync,writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createServer} from 'node:net';
import assert from 'node:assert/strict';

const listener=createServer();
await new Promise(resolve=>listener.listen(0,'127.0.0.1',resolve));
const port=listener.address().port;
await new Promise(resolve=>listener.close(resolve));
const directory=mkdtempSync(join(tmpdir(),'signalword-monitor-runtime-'));
const config=join(directory,'wrangler.json');
writeFileSync(config,JSON.stringify({name:'signalword-local-monitor-verification',
 main:fileURLToPath(new URL('../tests/fixtures/monitor-runtime.mjs',import.meta.url)),
 compatibility_date:'2026-09-28'}));
const child=spawn('npx',['--yes','wrangler@4.40.0','dev','--local','--ip','127.0.0.1','--port',String(port),'--config',config],
 {stdio:['ignore','ignore','ignore'],detached:true});
try {
 let result;
 const deadline=Date.now()+60000;
 while(Date.now()<deadline) {
  if(child.exitCode!==null) throw Error('LOCAL_WORKER_EXITED');
  try {const response=await fetch(`http://127.0.0.1:${port}`,{signal:AbortSignal.timeout(1500)});result=await response.json();break;}
  catch {await new Promise(resolve=>setTimeout(resolve,500));}
 }
 assert.equal(result?.passed,true,'Cloudflare runtime must accept all monitor requests and reject redirects');
 console.log(`PASS: Cloudflare workerd monitor runtime (${result.requests} request cases; no external pings).`);
} finally {
 if(child.exitCode===null) process.kill(-child.pid,'SIGTERM');
}
