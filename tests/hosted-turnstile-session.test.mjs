import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyInvitedLogin} from '../scripts/hosted-turnstile-session.mjs';
const input = {email:'fixture@example.invalid',password:'private-password',publishableKey:'public-key',captchaToken:'private-captcha'};
test('invited challenge uses pinned password login, revokes session, and returns only redacted scalars', async()=>{
 const calls=[];
 const result=await verifyInvitedLogin({...input,fetchImpl:async(url,options)=>{
  calls.push({url,options});
  return calls.length===1 ? Response.json({access_token:'private-session',user:{id:'private-user'}}):new Response(null,{status:204});
 }});
 assert.deepEqual(result,{status:200,accepted:true,logoutStatus:204});
 assert.equal(calls.length,2);
 assert.equal(calls[0].url,'https://voepalyamwgenceawdvl.supabase.co/auth/v1/token?grant_type=password');
 assert.equal(JSON.parse(calls[0].options.body).gotrue_meta_security.captcha_token,input.captchaToken);
 assert.equal(calls[0].options.redirect,'error');
 assert.equal(calls[1].options.headers.Authorization,'Bearer private-session');
 assert.ok(!JSON.stringify(result).includes('private'));
});
test('failed challenge never establishes a session or exposes provider error text',async()=>{
 let calls=0;
 const result=await verifyInvitedLogin({...input,fetchImpl:async()=>{calls++;return Response.json({error:'private-captcha'},{status:400});}});
 assert.equal(calls,1);assert.deepEqual(result,{status:400,accepted:false,logoutStatus:null});
});
test('missing session inputs fail before network',async()=>{
 await assert.rejects(verifyInvitedLogin({...input,captchaToken:'',fetchImpl:()=>{throw Error('unexpected network');}}),/SESSION_INPUT_REQUIRED/);
});
