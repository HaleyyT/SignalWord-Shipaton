import { randomBytes } from 'node:crypto';
import { pathToFileURL } from 'node:url';

/** Check routing and privacy headers without reading any real recipient capability. */
export async function checkHostedViewer(origin, fetchImpl = fetch) {
  const base = new URL(origin);
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash || base.pathname !== '/') {
    throw new Error('Set SIGNALWORD_VIEWER_ORIGIN to an HTTPS origin without a path or credentials.');
  }
  // This random, unissued token cannot identify a recipient. Never print it or bodies.
  const token = randomBytes(32).toString('base64url');
  const checks = [
    { name: 'Viewer deep link', path: `/events/${token}`, method: 'GET', html: true },
    { name: 'Confirmation deep link', path: `/confirm/${token}`, method: 'GET', html: true },
    { name: 'Event GET routing', path: `/v1/public/events/${token}`, method: 'GET' },
    { name: 'Acknowledgement POST routing', path: `/v1/public/events/${token}`, method: 'POST', action: 'acknowledge' },
    { name: 'Confirmation POST routing', path: `/api/v1/contacts/confirm/${token}`, method: 'POST', contact: true },
    { name: 'Withdrawal POST routing', path: `/api/v1/contacts/confirm/${token}`, method: 'POST', action: 'withdraw', contact: true },
  ];
  const results = [];
  for (const check of checks) {
    try {
      const response = await fetchImpl(new URL(check.path, base), {
        method: check.method, redirect: 'error', signal: AbortSignal.timeout(10_000),
        headers: check.action ? { 'X-SignalWord-Action': check.action } : {},
      });
      const problems = [];
      if (response.headers.get('referrer-policy') !== 'no-referrer') problems.push('missing no-referrer');
      if (response.headers.get('x-content-type-options') !== 'nosniff') problems.push('missing nosniff');
      if (!response.headers.get('strict-transport-security')) problems.push('missing HSTS');
      if (check.html) {
        if (response.status !== 200 || !response.headers.get('content-type')?.includes('text/html')) problems.push('expected HTML 200');
        const csp = response.headers.get('content-security-policy') ?? '';
        if (!csp.includes("frame-ancestors 'none'")) problems.push('missing anti-framing CSP');
        await response.body?.cancel();
      } else {
        if (![404, 410].includes(response.status)) problems.push('expected unavailable-token status');
        if (!response.headers.get('cache-control')?.includes('no-store')) problems.push('missing no-store');
        const body = await response.json().catch(() => null);
        // Contact links use a different public contract from event links.
        const unavailable = check.contact
          ? body?.confirmed === false && body?.unavailable === true
          : ['NOT_FOUND', 'LINK_UNAVAILABLE'].includes(body?.error?.code);
        if (!unavailable) problems.push('expected JSON unavailable-link error');
      }
      results.push({ name: check.name, passed: problems.length === 0, problems });
    } catch {
      // Fetch errors may include the capability URL; report only a safe category.
      results.push({ name: check.name, passed: false, problems: ['request failed or timed out'] });
    }
  }
  return results;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    const origin = process.env.SIGNALWORD_VIEWER_ORIGIN;
    if (!origin) throw new Error('Set SIGNALWORD_VIEWER_ORIGIN to the development viewer HTTPS origin.');
    const results = await checkHostedViewer(origin);
    for (const result of results) console.log(`${result.passed ? 'PASS' : 'FAIL'} ${result.name}${result.problems.length ? `: ${result.problems.join(', ')}` : ''}`);
    console.log('This checks hosting configuration, not live delivery, consent, or acknowledgement of a real TEST.');
    if (results.some((result) => !result.passed)) process.exitCode = 1;
  } catch (error) {
    console.error(error instanceof Error && error.message.startsWith('Set SIGNALWORD_') ? error.message : 'Invalid hosting configuration.');
    process.exitCode = 1;
  }
}
