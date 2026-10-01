import test from 'node:test';
import assert from 'node:assert/strict';
import {requestInvitedCode,verifyInvitedCode,backend} from '../apps/viewer/public/onboarding/invited-session.js';
test('invited OTP request pins development and disables account creation',async()=>{
 const r=await requestInvitedCode({email:' A@example.com ',publishableKey:'public',captchaToken:'proof',fetchImpl:async(url,options)=>{
 assert.equal(url,backend+'/auth/v1/otp');assert.equal(options.redirect,'error');assert.deepEqual(JSON.parse(options.body),{email:'a@example.com',create_user:false,gotrue_meta_security:{captcha_token:'proof'}});return new Response('{}');}});
 assert.equal(r.requestAccepted,true);
});
test('code verification redacts credentials and revokes accepted session',async()=>{
 let calls=0;const result=await verifyInvitedCode({email:'a@example.com',publishableKey:'public',code:'123456',fetchImpl:async(url,options)=>{
 calls++;if(calls===1){assert.equal(url,backend+'/auth/v1/verify');assert.deepEqual(JSON.parse(options.body),{email:'a@example.com',token:'123456',type:'email'});return Response.json({access_token:'private-session',user:{id:'private-user'}});}
 assert.equal(url,backend+'/auth/v1/logout?scope=local');return new Response(null,{status:204});}});
 assert.deepEqual(result,{status:200,accepted:true,logoutStatus:204});assert.equal(calls,2);
});
test('expired replay or deleted-user rejection never becomes acceptance',async()=>{
 for(const status of [400,401,403,422,429,503]) {
 const result=await verifyInvitedCode({email:'a@example.com',publishableKey:'public',code:'123456',fetchImpl:async()=>Response.json({message:'private provider details'},{status})});
 assert.deepEqual(result,{status,accepted:false,logoutStatus:null});
 }
});

test('request diagnostics allowlist codes without leaking provider text',async()=>{
 for(const error_code of ['signup_disabled','otp_disabled','private-user@example.com']) {
  const r=await requestInvitedCode({email:'a@example.com',publishableKey:'public',captchaToken:'proof',fetchImpl:async()=>Response.json({error_code,message:'private details'},{status:422})});
  assert.equal(r.requestAccepted,false);assert.equal(r.rejection,error_code.includes('@')?undefined:error_code);assert.ok(!JSON.stringify(r).includes('private'));
 }
});
