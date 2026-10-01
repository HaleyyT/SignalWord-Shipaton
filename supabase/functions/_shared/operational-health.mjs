const schedules = new Map([
  ['signalword-dispatch-sweep', 180],
  ['signalword-delivery-lease-recovery', 180],
  ['signalword-hourly-retention', 4500],
]);
const nonnegative = value => typeof value === 'number' && Number.isFinite(value) && value >= 0;

/** Interpret aggregate health without copying any server-provided free text. */
export function operationalProblems(health, now = Date.now(), { maximumSignups = 100, maximumInvitations = 200 } = {}) {
  const problems = [];
  if (health?.dispatchConfigured !== true) problems.push('DISPATCH_CONFIGURATION_MISSING');
  for (const [key, label] of [['delivery', 'ALERT'], ['contactDelivery', 'CONTACT']]) {
    const value = health?.[key];
    if (!value || !['queued', 'unknown', 'oldestQueuedSeconds', 'expiredLeases'].every(field => nonnegative(value[field]))) {
      problems.push(`${label}_METRICS_INVALID`);
      continue;
    }
    if (value.queued > 100) problems.push(`${label}_QUEUE_BACKLOG`);
    if (value.unknown > 0) problems.push(`${label}_OUTCOME_UNKNOWN`);
    if (value.oldestQueuedSeconds > 60) problems.push(`${label}_QUEUE_OVER_60_SECONDS`);
    if (value.expiredLeases > 0) problems.push(`${label}_LEASE_EXPIRED`);
  }
  for (const [name, maximumAge] of schedules) {
    const row = Array.isArray(health?.schedules) ? health.schedules.find(row => row?.name === name) : null;
    const last = typeof row?.lastSuccessAt === 'string' ? Date.parse(row.lastSuccessAt) : NaN;
    if (row?.active !== true || !Number.isFinite(last) || last > now || now - last > maximumAge * 1000) {
      problems.push(`SCHEDULE_UNHEALTHY:${name}`);
    }
  }
  if (health?.checkIns !== undefined) {
    const timers = health.checkIns;
    if (!nonnegative(timers?.overdue) || !nonnegative(timers?.failed)) problems.push('CHECK_IN_METRICS_INVALID');
    else {
      if (timers.overdue > 0) problems.push('CHECK_IN_OVERDUE');
      if (timers.failed > 0) problems.push('CHECK_IN_FAILED');
    }
    for (const [name, age] of [['signalword-check-in-expiry',180],['signalword-check-in-retention',4500]]) {
      const row = Array.isArray(timers?.schedules) ? timers.schedules.find(row => row?.name === name) : null;
      const completed = Date.parse(row?.lastSuccessAt ?? '');
      if (row?.active !== true || !Number.isFinite(completed) || completed > now || now-completed > age*1000) problems.push(`SCHEDULE_UNHEALTHY:${name}`);
    }
  }
  const dispatch = health?.dispatchHTTP;
  const completed = Date.parse(dispatch?.lastCompletedAt ?? '');
  if (!dispatch || !Number.isFinite(completed) || completed > now || now - completed > 180_000 ||
      !Number.isInteger(dispatch.lastStatus) || dispatch.lastStatus < 200 || dispatch.lastStatus >= 300 ||
      dispatch.timedOut !== false || !nonnegative(dispatch.overdue) || dispatch.overdue > 0) {
    problems.push('DISPATCH_HTTP_UNHEALTHY');
  }
  if (!nonnegative(health?.abuse?.signupsLastHour) || !nonnegative(health?.abuse?.invitationsLastHour)) {
    problems.push('ABUSE_METRICS_INVALID');
  } else {
    if (health.abuse.signupsLastHour > maximumSignups) problems.push('SIGNUP_VOLUME_HIGH');
    if (health.abuse.invitationsLastHour > maximumInvitations) problems.push('INVITATION_VOLUME_HIGH');
  }
  if (!nonnegative(health?.journal?.pending) || !nonnegative(health?.journal?.oldestPendingSeconds)) problems.push('JOURNAL_METRICS_INVALID');
  else if (health.journal.oldestPendingSeconds > 60) problems.push('JOURNAL_PERSISTENCE_OVERDUE');
  if (!nonnegative(health?.provider?.callbackOverdue) || !nonnegative(health?.provider?.deliveryReportOverdue)) problems.push('PROVIDER_METRICS_INVALID');
  else {
    if (health.provider.callbackOverdue > 0) problems.push('PROVIDER_CALLBACK_OVERDUE');
    if (health.provider.deliveryReportOverdue > 0) problems.push('PROVIDER_DELIVERY_REPORT_OVERDUE');
  }
  return problems;
}

