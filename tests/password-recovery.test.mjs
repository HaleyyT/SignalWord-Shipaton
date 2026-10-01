import test from 'node:test';
import assert from 'node:assert/strict';
import {recoveryToken,recoveryClient,recoveryOrigin} from '../apps/viewer/public/auth/recovery-client.js';
const token='a'.repeat(64), configuration={backend:'https://voepalyamwgenceawdvl.supabase.co',publicKey:'fixture-public'};
test('Only correctly typed recovery hashes are accepted',()=>{
 assert.equal(recoveryToken('#token_hash='+token+'&type=recovery'),token);
 for(const value of ['#access_token=unsafe','#token_hash='+token+'&type=email','#token_hash=wrong&type=recovery'])assert.equal(recoveryToken(value),null);
});
test('Recovery is verified once on explicit update, then changes the existing account and revokes only that session',async()=>{
 const calls=[];const client=recoveryClient(configuration,async(url,options)=>{
 calls.push({url,options});return Response.json(url.endsWith('/verify')?{access_token:'recovery-session'}:{});
 });
 assert.equal(calls.length,0);await client.update(token,'fixture-password');
 assert.equal(calls.length,3);assert.deepEqual(JSON.parse(calls[0].options.body),{token_hash:token,type:'recovery'});
 assert.equal(calls[1].options.method,'PUT');assert.equal(calls[1].options.headers.Authorization,'Bearer recovery-session');
 assert.ok(calls[2].url.endsWith('/logout?scope=local'));
});
test('Expired or reused links cannot update an account',async()=>{
 let count=0;const client=recoveryClient(configuration,async()=>{count++;return Response.json({code:'otp_expired'},{status:403});});
 await assert.rejects(client.update(token,'fixture-password'),/LINK_OR_PASSWORD_NOT_ACCEPTED/);assert.equal(count,1);
});
test('Reset request includes CAPTCHA and exact HTTPS recovery redirect',async()=>{
 const client=recoveryClient(configuration,async(url,options)=>{
 assert.equal(new URL(url).searchParams.get('redirect_to'),recoveryOrigin);
 assert.deepEqual(JSON.parse(options.body),{email:'fixture@example.test',gotrue_meta_security:{captcha_token:'proof'}});return Response.json({});
 });await client.request('fixture@example.test','proof');
});
test('Recovery refuses another backend and classifies quota rejection',async()=>{
 assert.throws(()=>recoveryClient({...configuration,backend:'http://localhost:3000'}),/CONFIGURATION/);
 const client=recoveryClient(configuration,async()=>Response.json({},{status:429}));
 await assert.rejects(client.request('fixture@example.test','proof'),/RATE_LIMITED/);
});
