import {recoveryToken,recoveryClient} from './recovery-client.js';
let tokenHash = recoveryToken(location.hash);
const hadFragment=!!location.hash;
// Read once into memory, then remove all credentials before any network request.
history.replaceState(null,'',location.pathname);
const status=document.getElementById('status'), request=document.getElementById('request'), reset=document.getElementById('reset'), fresh=document.getElementById('fresh');
let client, captcha, widget, busy=false;
function message(error) {
  return error.message==='RATE_LIMITED'?'Too many attempts. Wait a few minutes and try again.':error.message==='CAPTCHA'?'Verification failed. Complete a new CAPTCHA.':error.message==='UNAVAILABLE'?'The account service is temporarily unavailable. Try again.':'The link or password was not accepted. Links expire and can only be used once. Request a fresh link if needed.';
}
async function startRequest() {
  tokenHash=null; reset.hidden=true; request.hidden=false; fresh.hidden=true;
  status.textContent='Enter your existing account email and complete verification.';
  if(widget!==undefined){window.turnstile.reset(widget);return;}
  const config=await fetch('/api/auth/config',{cache:'no-store'}).then(r=>{if(!r.ok)throw Error('UNAVAILABLE');return r.json();});
  const script=document.createElement('script');script.src='https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
  script.onerror=()=>{status.textContent='Verification could not load. Check your connection and reload.';};
  script.onload=()=>{widget=window.turnstile.render('#challenge',{sitekey:config.siteKey,action:'signup',theme:'dark',callback:token=>{captcha=token;document.getElementById('send').disabled=false;},'expired-callback':()=>{captcha=null;document.getElementById('send').disabled=true;},'error-callback':()=>{captcha=null;document.getElementById('send').disabled=true;status.textContent='Verification could not finish. Reload and try again.';}});};
  document.head.append(script);
}
fresh.addEventListener('click',()=>startRequest().catch(error=>{status.textContent=message(error);}));
request.addEventListener('submit',async event=>{
  event.preventDefault();if(busy||!captcha)return;busy=true;document.getElementById('send').disabled=true;
  try {await client.request(document.getElementById('email').value,captcha);status.textContent='If this email has an account, a reset link has been sent. Check your inbox and spam folder.';}
  catch(error){status.textContent=message(error);}
  finally{busy=false;captcha=null;if(widget!==undefined)window.turnstile.reset(widget);}
});
reset.addEventListener('submit',async event=>{
  event.preventDefault();if(busy||!tokenHash)return;
  const input=document.getElementById('password'), confirmation=document.getElementById('confirmation');
  if(input.value!==confirmation.value){status.textContent='The passwords do not match.';return;}
  busy=true;document.getElementById('update').disabled=true;
  try{await client.update(tokenHash,input.value);tokenHash=null;reset.hidden=true;status.textContent='Password updated. Return to SignalWord and sign in with your new password.';}
  catch(error){status.textContent=message(error);fresh.hidden=false;}
  finally{input.value='';confirmation.value='';busy=false;document.getElementById('update').disabled=false;}
});
try{
  const response=await fetch('/api/auth/config',{cache:'no-store'});if(!response.ok)throw Error('UNAVAILABLE');client=recoveryClient(await response.json());
  if(tokenHash){reset.hidden=false;status.textContent='Choose a new password with at least 8 characters. Your link is verified only when you submit.';}
  else if(hadFragment){status.textContent='This recovery link is invalid or expired. Request a fresh link.';fresh.hidden=false;}
  else await startRequest();
}catch(error){status.textContent=message(error);}
