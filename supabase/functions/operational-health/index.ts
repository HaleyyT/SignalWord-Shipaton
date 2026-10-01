import { operationalProblems } from '../_shared/operational-health.mjs';
import { jsonResponse } from '../_shared/http.ts';

// Hash before comparing so mismatched credential lengths do not short-circuit.
async function matches(actual: string, expected: string): Promise<boolean> {
  if (expected.length < 32) return false;
  const digest = async (s: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s)));
  const [a,b] = await Promise.all([digest(actual),digest(expected)]);
  let difference = 0;
  for (let i=0;i<a.length;i++) difference |= a[i]^b[i];
  return difference === 0;
}
export function createHealthHandler(config: {
  key: string; previousKey?: string; read: () => Promise<unknown>;
}) {
  return async (request: Request): Promise<Response> => {
    const token = (request.headers.get('Authorization') ?? '').replace(/^Bearer /,'');
    const accepted = await matches(token,config.key);
    const previousAccepted = await matches(token,config.previousKey ?? '');
    if (!accepted && !previousAccepted) return jsonResponse({error:'UNAUTHORIZED'},401);
    if (request.method !== 'GET') return jsonResponse({error:'METHOD_NOT_ALLOWED'},405);
    try {
      // Return only fixed problem codes. Never return database rows or diagnostics.
      return jsonResponse({problems:operationalProblems(await config.read())},200);
    } catch { return jsonResponse({error:'HEALTH_UNAVAILABLE'},503); }
  };
}
if (import.meta.main) {
  const url=Deno.env.get('SUPABASE_URL')!;
  const key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  Deno.serve(createHealthHandler({
    key:Deno.env.get('MONITOR_SECRET') ?? '',previousKey:Deno.env.get('MONITOR_PREVIOUS_SECRET'),
    read:async()=>{
      const result=await fetch(`${url}/rest/v1/rpc/signalword_operational_health`,{
        method:'POST',redirect:'error',signal:AbortSignal.timeout(5000),
        headers:{apikey:key,Authorization:`Bearer ${key}`,'Content-Type':'application/json'},body:'{}'
      });
      if(!result.ok) throw new Error('HEALTH_UNAVAILABLE');
      return await result.json();
    }
  }));
}
