import {checkOperations, reportHeartbeatResult} from '../../supabase/functions/_shared/monitor-client.mjs';

// Local-only workerd fixture. Request construction exercises the real runtime;
// responses are synthetic, so this test never calls a provider or sends a ping.
export default {async fetch() {
  const requests=[];
  const provider=async(url,init)=>{
    const request=new Request(url,init);
    requests.push(request.redirect);
    return String(url).includes('operational-health')
      ? Response.json({problems:[]}) : new Response('OK');
  };
  const result=await checkOperations({backendOrigin:'https://backend.example',monitorKey:'fixture-key',fetchImpl:provider});
  const ping='https://hc-ping.com/00000000-0000-4000-8000-000000000001';
  const healthy=await reportHeartbeatResult(ping,true,provider);
  const failed=await reportHeartbeatResult(ping,false,provider);
  const redirected=await reportHeartbeatResult(ping,true,async(url,init)=>{
    requests.push(new Request(url,init).redirect);
    return new Response(null,{status:302,headers:{Location:'https://untrusted.example/'}});
  });
  const passed=result.problems.length===0 && healthy.accepted && failed.accepted &&
    !redirected.accepted && requests.length===4 && requests.every(mode=>mode==='manual');
  return Response.json({passed,requests:requests.length},{status:passed?200:500});
}};
