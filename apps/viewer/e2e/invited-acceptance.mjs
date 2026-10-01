import { chromium } from '@playwright/test';
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const browser = await chromium.launch({headless:true});
try {
 const page=await browser.newPage(); let logins=0, logouts=0, expiry=false, otpVerifications=0;
 await page.route('https://www.signalword.app/onboarding/**',async route=>{
  const name=new URL(route.request().url()).pathname.split('/').pop();
  if(!['acceptance.html','acceptance.js','invited-session.js','verify.css'].includes(name)) throw Error('UNEXPECTED_ASSET');
  await route.fulfill({body:await readFile(new URL('../public/onboarding/'+name,import.meta.url)),contentType:name.endsWith('.html')?'text/html':name.endsWith('.css')?'text/css':'application/javascript'});
 });
 await page.route('https://challenges.cloudflare.com/**',route=>route.fulfill({contentType:'application/javascript',body:`window.turnstile={render(target,options){const b=document.createElement('button');b.textContent='Simulated human challenge';b.onclick=()=>options.callback('fixture-captcha');document.querySelector(target).appendChild(b);}};`}));
 await page.route('https://voepalyamwgenceawdvl.supabase.co/**',async route=>{
  const req=route.request(); const url=new URL(req.url());
  if(url.pathname==='/auth/v1/token') {
   logins++; assert.equal(req.postDataJSON().gotrue_meta_security.captcha_token,'fixture-captcha');
   await route.fulfill({status:logins===1?200:400,contentType:'application/json',body:JSON.stringify(logins===1?{access_token:'private-session',user:{id:'private-user'}}:expiry?{error_code:'captcha_failed'}:{error:'private-provider-error'})});
  } else if(url.pathname==='/auth/v1/otp') {
   assert.equal(req.postDataJSON().create_user,false);await route.fulfill({status:200,body:'{}',contentType:'application/json'});
  } else if(url.pathname==='/auth/v1/verify') {
   otpVerifications++;assert.equal(req.postDataJSON().type,'email');
   await route.fulfill({status:otpVerifications===2?200:403,contentType:'application/json',body:JSON.stringify(otpVerifications===2?{access_token:'private-otp-session',user:{id:'private-user'}}:{error_code:'otp_expired'})});
  } else if(url.pathname==='/auth/v1/signup') { await route.fulfill({status:422,contentType:'application/json',body:JSON.stringify({error_code:'signup_disabled'})});
  } else if(url.pathname==='/auth/v1/logout') {logouts++;await route.fulfill({status:204,body:''});}
  else throw Error('UNEXPECTED_NETWORK');
 });
 await page.goto('https://www.signalword.app/onboarding/acceptance.html');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',password:'private-password',publishableKey:'public-client-key'}))});
 await page.getByRole('button',{name:'Simulated human challenge'}).click();
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 const result=JSON.parse(await page.locator('#evidence').innerText());
 assert.equal(result.passed,true);assert.equal(logins,2);assert.equal(logouts,1);
 const body=await page.locator('body').innerText();
 for(const forbidden of ['private@example.invalid','private-password','fixture-captcha','private-session','private-provider-error']) assert.ok(!body.includes(forbidden));
 assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
 assert.equal(await page.locator('#fixture').inputValue(),'');
 await page.reload();
 await page.locator('#mode').selectOption('closed');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',password:'private-password',publishableKey:'public-client-key'}))});
 await page.getByRole('button',{name:'Simulated human challenge'}).click();
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).scope,'closed-enrollment');
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).passed,true);

 await page.reload();
 await page.locator('#mode').selectOption('otp');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',publishableKey:'public-client-key'}))});
 await page.getByRole('button',{name:'Simulated human challenge'}).click();
 await page.locator('#otp-code').fill('12345678');
 await page.locator('#otp-verify').click();
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 const otp=JSON.parse(await page.locator('#evidence').innerText());
 assert.equal(otp.scope,'invited-email-code');assert.equal(otp.passed,true);assert.equal(otpVerifications,3);
 assert.equal(await page.locator('#otp-code').inputValue(),'');
 assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
 for(const forbidden of ['123456','private@example.invalid','private-otp-session'])assert.ok(!(await page.locator('#evidence').innerText()).includes(forbidden));
 await page.reload();otpVerifications=0;
 await page.locator('#mode').selectOption('invite');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',publishableKey:'public-client-key'}))});
 await page.locator('#otp-code').fill('12345678');await page.locator('#otp-verify').click();
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).scope,'operator-invitation-code');
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).passed,true);
 await page.reload(); await page.clock.install();otpVerifications=3;
 await page.locator('#mode').selectOption('otp-expiry');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',publishableKey:'public-client-key'}))});
 await page.getByRole('button',{name:'Simulated human challenge'}).click();
 await page.locator('#otp-code').fill('12345678');await page.locator('#otp-verify').click();
 assert.equal(otpVerifications,3);await page.clock.fastForward(3610001);
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).scope,'unused-email-code-expiry');
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).passed,true);
 await page.reload(); expiry=true;
 await page.locator('#mode').selectOption('expired');
 await page.locator('#fixture').setInputFiles({name:'fixture.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'development',signupDisabled:true,email:'private@example.invalid',password:'private-password',publishableKey:'public-client-key'}))});
 await page.getByRole('button',{name:'Simulated human challenge'}).click();
 assert.equal(logins,2); await page.clock.fastForward(310001);
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 const expired=JSON.parse(await page.locator('#evidence').innerText());
 assert.equal(expired.scope,'unused-token-expiry');assert.equal(expired.passed,true);assert.equal(logins,3);
 await page.reload();
 await page.locator('#fixture').setInputFiles({name:'bad.json',mimeType:'application/json',buffer:Buffer.from(JSON.stringify({environment:'production',signupDisabled:true}))});
 await page.getByRole('button',{name:'Save redacted result'}).waitFor();
 assert.equal(JSON.parse(await page.locator('#evidence').innerText()).failure,'INVALID_DEVELOPMENT_FIXTURE');
 assert.equal(logins,3);
 console.log('PASS mocked normal-browser harness: invited login, logout, token reuse rejection, redaction, no storage, wrong-environment rejection. NOT real CAPTCHA evidence.');
} finally {await browser.close();}
