import { pathToFileURL } from 'node:url';

import { operationalProblems } from '../supabase/functions/_shared/operational-health.mjs';
export { operationalProblems };

import { checkOperations, reportHeartbeat } from '../supabase/functions/_shared/monitor-client.mjs';
export { checkOperations, reportHeartbeat };

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const { SIGNALWORD_BACKEND_ORIGIN: backendOrigin, SIGNALWORD_MONITOR_KEY: monitorKey,
      SIGNALWORD_OPERATOR_WEBHOOK: notificationURL, SIGNALWORD_MONITOR_HEARTBEAT_URL: heartbeatURL } = process.env;
    if (!backendOrigin || !monitorKey || !heartbeatURL) throw new Error('configuration');
    const result = await checkOperations({ backendOrigin, monitorKey, notificationURL });
    const heartbeatRecorded = await reportHeartbeat(heartbeatURL, result.problems.length === 0);
    console.log(JSON.stringify({ ...result, heartbeatRecorded }));
    if (result.problems.length || !heartbeatRecorded) process.exitCode = 1;
  } catch {
    console.error('Operational check failed. Verify backend, scoped monitor credential, heartbeat and threshold configuration in secret storage.');
    process.exitCode = 1;
  }
}
