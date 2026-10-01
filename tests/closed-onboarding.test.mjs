import test from 'node:test';
import assert from 'node:assert/strict';
import {verifyClosedEnrollment,verifyInvitedLogin} from '../apps/viewer/public/onboarding/invited-session.js';
const input={email:'fixture@example.invalid',password:'fixture-password',publishableKey:'fixture-public',captchaToken:'fixture-human'};
test('closed enrollment requires explicit signup_disabled, not an arbitrary failure',async()=>{
 for(const [code,passed] of [['signup_disabled',true],['captcha_failed',false],['unexpected',false]]) {
  const r=await verifyClosedEnrollment({...input,fetchImpl:async(url,options)=>{
   assert.equal(url,'https://voepalyamwgenceawdvl.supabase.co/auth/v1/signup');assert.equal(options.redirect,'error');
   assert.match(JSON.parse(options.body).email,/@example.invalid$/);
   return Response.json({error_code:code,private:'must not escape'},{status:422});
  }});
  assert.equal(r.passed,passed);assert.ok(!JSON.stringify(r).includes('must not escape'));
 }
});
test('expired proof requires a CAPTCHA rejection; ordinary authentication errors are not expiry evidence',async()=>{
 for(const code of ['captcha_failed','invalid_credentials']) {
  const r=await verifyInvitedLogin({...input,fetchImpl:async()=>Response.json({code},{status:400})});
  assert.equal(r.rejection,code==='captcha_failed'?'captcha_failed':undefined);assert.equal(r.accepted,false);
 }
});
