/** Existing invited identity only. Never creates users or stores returned sessions. */
export const backend = 'https://voepalyamwgenceawdvl.supabase.co';
export async function verifyInvitedLogin({ email, password, publishableKey, captchaToken, fetchImpl = fetch }) {
  if (!email || !password || !publishableKey || !captchaToken) throw Error('SESSION_INPUT_REQUIRED');
  const response = await fetchImpl(`${backend}/auth/v1/token?grant_type=password`, {
    method: 'POST', redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(20000),
    headers: { apikey: publishableKey, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password, gotrue_meta_security: { captcha_token: captchaToken } }),
  });
  const body = await response.json().catch(() => null);
  const accepted = response.ok && typeof body?.access_token === 'string' && !!body?.user?.id;
  // Revoke the temporary session immediately. Never return or persist its tokens.
  let logoutStatus = null;
  if (accepted) {
    const logout = await fetchImpl(`${backend}/auth/v1/logout?scope=local`, {
      method: 'POST', redirect: 'error', cache: 'no-store', signal: AbortSignal.timeout(20000),
      headers: { apikey: publishableKey, Authorization: `Bearer ${body.access_token}` },
    });
    logoutStatus = logout.status;
  }
  return { status: response.status, accepted, logoutStatus, ...(body?.error_code === "captcha_failed" || body?.code === "captcha_failed" ? {rejection:"captcha_failed"} : {}) };
}

/** Closed enrollment probe: a fresh human token must still be refused by Auth. */
export async function verifyClosedEnrollment({password,publishableKey,captchaToken,fetchImpl=fetch}) {
  if (!password || !publishableKey || !captchaToken) throw Error('SESSION_INPUT_REQUIRED');
  const response=await fetchImpl(`${backend}/auth/v1/signup`,{
    method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(20000),
    headers:{apikey:publishableKey,'Content-Type':'application/json'},
    body:JSON.stringify({email:`signalword-closed-probe-${crypto.randomUUID()}@example.invalid`,password,gotrue_meta_security:{captcha_token:captchaToken}}),
  });
  const body=await response.json().catch(()=>null);
  const disabled=(body?.error_code ?? body?.code)==='signup_disabled';
  return {status:response.status,signupDisabled:disabled,passed:!response.ok && disabled};
}

/** Same wire contract as the native invited email-code flow. Never creates users. */
export async function requestInvitedCode({email,publishableKey,captchaToken,fetchImpl=fetch}) {
  if (!email || !publishableKey || !captchaToken) throw Error('SESSION_INPUT_REQUIRED');
  const response=await fetchImpl(`${backend}/auth/v1/otp`,{
    method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(20000),
    headers:{apikey:publishableKey,'Content-Type':'application/json'},
    body:JSON.stringify({email:email.trim().toLowerCase(),create_user:false,gotrue_meta_security:{captcha_token:captchaToken}}),
  });
  const body=await response.json().catch(()=>null);
  const code=body?.error_code ?? body?.code;
  const allowed=['signup_disabled','otp_disabled','email_provider_disabled','over_email_send_rate_limit','over_request_rate_limit','captcha_failed','unexpected_failure'];
  return {status:response.status,requestAccepted:response.ok,...(allowed.includes(code)?{rejection:code}:{})};
}
export async function verifyInvitedCode({email,publishableKey,code,fetchImpl=fetch}) {
  if(!email || !publishableKey || !/^[0-9]{6,10}$/.test(code))throw Error('SESSION_INPUT_REQUIRED');
  const response=await fetchImpl(`${backend}/auth/v1/verify`,{
    method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(20000),
    headers:{apikey:publishableKey,'Content-Type':'application/json'},
    body:JSON.stringify({email:email.trim().toLowerCase(),token:code,type:'email'}),
  });
  const body=await response.json().catch(()=>null);
  const accepted=response.ok && typeof body?.access_token==='string' && !!body?.user?.id;
  let logoutStatus=null;
  if(accepted) {
    const logout=await fetchImpl(`${backend}/auth/v1/logout?scope=local`,{method:'POST',redirect:'error',cache:'no-store',signal:AbortSignal.timeout(20000),headers:{apikey:publishableKey,Authorization:`Bearer ${body.access_token}`}});
    logoutStatus=logout.status;
  }
  return {status:response.status,accepted,logoutStatus,...(body?.error_code==='otp_expired'?{rejection:'otp_expired'}:{})};
}
