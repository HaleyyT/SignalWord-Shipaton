export function validProblems(value) {
  return Array.isArray(value) && value.length <= 32 && value.every(code =>
    typeof code === 'string' && /^(?:[A-Z_0-9]+|SCHEDULE_UNHEALTHY:signalword-[a-z-]+)$/.test(code) && code.length <= 100);
}

// Workers reject redirect:error; manual plus response.ok checks reject redirects without forwarding credentials.
export async function checkOperations({ backendOrigin, monitorKey, notificationURL, fetchImpl = fetch }) {
  const origin = new URL(backendOrigin);
  if (origin.protocol !== 'https:' || origin.pathname !== '/' || origin.username || origin.password || origin.search || origin.hash || !monitorKey) {
    throw new Error('OPERATIONAL_CONFIGURATION_INVALID');
  }
  let problems;
  try {
    const response = await fetchImpl(new URL('/functions/v1/operational-health', origin), {
      method: 'GET', redirect: 'manual', signal: AbortSignal.timeout(10_000),
      headers: { Authorization: `Bearer ${monitorKey}` },
    });
    const body = response.ok ? await response.json() : null;
    problems = validProblems(body?.problems) ? body.problems : ['HEALTH_RPC_UNAVAILABLE'];
  } catch { problems = ['HEALTH_RPC_UNAVAILABLE']; }

  let notified = false;
  if (problems.length && notificationURL) {
    // Configure a dedicated operator webhook accepting this small JSON contract.
    // No event IDs or secret-bearing request data are copied into notifications.
    try {
      const destination = new URL(notificationURL);
      if (destination.protocol !== 'https:' || destination.username || destination.password) throw new Error();
      const response = await fetchImpl(destination, {
        method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(10_000),
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ service: 'SignalWord', severity: 'critical', problems }),
      });
      notified = response.ok;
    } catch { /* The caller must fail visibly when the notification path fails. */ }
  }
  return { problems, notified };
}

/** An external dead-man check also detects when this monitor stops running. */
export async function reportHeartbeat(heartbeatURL, healthy, fetchImpl = fetch) {
  return (await reportHeartbeatResult(heartbeatURL, healthy, fetchImpl)).accepted;
}

/** Fixed diagnostic codes only: provider bodies and capability URLs stay private. */
export async function reportHeartbeatResult(heartbeatURL, healthy, fetchImpl = fetch) {
  let url;
  try {
    url = new URL(heartbeatURL);
    if (url.protocol !== 'https:' || url.hostname !== 'hc-ping.com' || url.port || url.username || url.password ||
        url.search || url.hash || !/^\/[0-9a-f-]{36}$/.test(url.pathname)) return {accepted:false,code:'PING_CONFIGURATION_INVALID'};
  } catch { return {accepted:false,code:'PING_CONFIGURATION_INVALID'}; }
  if (!healthy) url.pathname += '/fail';
  try {
    const response = await fetchImpl(url, { method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(10_000) });
    if (!response.ok) return {accepted:false,code:'PING_HTTP_ERROR'};
    // Healthchecks returns HTTP 200 even for unknown checks and rate limiting.
    const body = (await response.text()).trim();
    return body === 'OK' ? {accepted:true,code:'PING_ACCEPTED'} : {accepted:false,code:'PING_NOT_ACCEPTED'};
  } catch { return {accepted:false,code:'PING_NETWORK_ERROR'}; }
}
