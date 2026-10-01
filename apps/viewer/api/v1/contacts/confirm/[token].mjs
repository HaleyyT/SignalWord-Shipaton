const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_RESPONSE_BYTES = 8_192;

const securityHeaders = {
  'Cache-Control': 'no-store',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
};

export async function proxyContactConfirmation({ token, upstreamOrigin, fetchImpl = fetch, action = 'confirm' }) {
  if (!TOKEN_PATTERN.test(token)) {
    return { status: 410, headers: securityHeaders, body: { confirmed: false, unavailable: true } };
  }
  let origin;
  try { origin = new URL(upstreamOrigin); } catch { origin = null; }
  if (!origin || (origin.protocol !== 'https:' && !['127.0.0.1', 'localhost'].includes(origin.hostname))) {
    return { status: 503, headers: securityHeaders, body: { confirmed: false, retryable: true } };
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8_000);
  try {
    const response = await fetchImpl(
      `${origin.toString().replace(/\/$/, '')}/v1/contacts/confirm/${encodeURIComponent(token)}`,
      { method: 'POST', headers: { Accept: 'application/json', ...(action === 'withdraw' ? { 'X-SignalWord-Action': 'withdraw' } : {}) }, redirect: 'error', signal: controller.signal },
    );
    const declaredLength = Number(response.headers.get('Content-Length') ?? 0);
    if (declaredLength > MAX_RESPONSE_BYTES) throw new Error('UPSTREAM_RESPONSE_TOO_LARGE');
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > MAX_RESPONSE_BYTES) throw new Error('UPSTREAM_RESPONSE_TOO_LARGE');
    const payload = JSON.parse(text);
    if (response.status === 200 && payload?.[action === 'withdraw' ? 'withdrawn' : 'confirmed'] === true) {
      return { status: 200, headers: securityHeaders, body: action === 'withdraw' ? { withdrawn: true } : { confirmed: true } };
    }
    if (response.status === 404 || response.status === 410) {
      return { status: 410, headers: securityHeaders, body: { confirmed: false, unavailable: true } };
    }
    return { status: 503, headers: securityHeaders, body: { confirmed: false, retryable: true } };
  } catch {
    return { status: 503, headers: securityHeaders, body: { confirmed: false, retryable: true } };
  } finally {
    clearTimeout(timeout);
  }
}

export default async function handler(request, response) {
  if (request.method !== 'POST') {
    response.status(405).setHeader('Allow', 'POST').json({ confirmed: false });
    return;
  }
  const token = Array.isArray(request.query.token) ? request.query.token[0] : request.query.token;
  const actionHeader = request.headers['x-signalword-action'];
  if (actionHeader !== undefined && actionHeader !== 'withdraw') {
    response.status(400).json({ error: { code: 'INVALID_REQUEST' } }); return;
  }
  const result = await proxyContactConfirmation({
    token: typeof token === 'string' ? token : '',
    upstreamOrigin: process.env.SIGNALWORD_CONTACT_CONFIRM_ORIGIN ?? '',
    action: actionHeader === 'withdraw' ? 'withdraw' : 'confirm',
  });
  for (const [name, value] of Object.entries(result.headers)) response.setHeader(name, value);
  response.status(result.status).json(result.body);
}
