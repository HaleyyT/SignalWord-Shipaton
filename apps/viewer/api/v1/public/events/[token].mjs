const TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_RESPONSE_BYTES = 32_768;

const securityHeaders = {
  'Cache-Control': 'no-store',
  'Content-Security-Policy': "default-src 'none'; frame-ancestors 'none'; base-uri 'none'",
  'Referrer-Policy': 'no-referrer',
  'X-Content-Type-Options': 'nosniff',
};

export async function proxyPublicEvent({ token, upstreamOrigin, fetchImpl = fetch, method = 'GET' }) {
  if (!TOKEN_PATTERN.test(token)) {
    return { status: 404, headers: securityHeaders, body: { error: { code: 'NOT_FOUND', message: 'This alert is unavailable.', retryable: false } } };
  }
  let origin;
  try {
    origin = new URL(upstreamOrigin);
  } catch {
    return { status: 503, headers: securityHeaders, body: { error: { code: 'SERVICE_UNAVAILABLE', message: 'The alert is temporarily unavailable.', retryable: true } } };
  }
  if (origin.protocol !== 'https:' && origin.hostname !== '127.0.0.1' && origin.hostname !== 'localhost') {
    return { status: 503, headers: securityHeaders, body: { error: { code: 'SERVICE_UNAVAILABLE', message: 'The alert is temporarily unavailable.', retryable: true } } };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8_000);
  try {
    const response = await fetchImpl(
      `${origin.toString().replace(/\/$/, '')}/v1/public/events/${encodeURIComponent(token)}`,
      { method, headers: { Accept: 'application/json', ...(method === 'POST' ? {'X-SignalWord-Action': 'acknowledge'} : {}) }, redirect: 'error', signal: controller.signal },
    );
    const declaredLength = Number(response.headers.get('Content-Length') ?? 0);
    if (declaredLength > MAX_RESPONSE_BYTES) throw new Error('UPSTREAM_RESPONSE_TOO_LARGE');
    const text = await response.text();
    if (new TextEncoder().encode(text).byteLength > MAX_RESPONSE_BYTES) throw new Error('UPSTREAM_RESPONSE_TOO_LARGE');
    const upstreamBody = JSON.parse(text);
    const status = response.status === 200 || response.status === 404 || response.status === 410 ||
      response.status === 429 || response.status >= 500 ? response.status : 503;
    const headers = { ...securityHeaders };
    const retryAfter = response.headers.get('Retry-After');
    if (retryAfter && (status === 429 || status >= 500)) headers['Retry-After'] = retryAfter;
    const body = status === 200 ? upstreamBody : status === 404 || status === 410
      ? { error: { code: 'NOT_FOUND', message: 'This alert is unavailable.', retryable: false } }
      : status === 429
      ? { error: { code: 'RATE_LIMITED', message: 'Too many requests. Try again shortly.', retryable: true } }
      : { error: { code: 'SERVICE_UNAVAILABLE', message: 'The alert is temporarily unavailable.', retryable: true } };
    return { status, headers, body };
  } catch {
    return { status: 503, headers: securityHeaders, body: { error: { code: 'SERVICE_UNAVAILABLE', message: 'The alert is temporarily unavailable.', retryable: true } } };
  } finally {
    clearTimeout(timeout);
  }
}

export default async function handler(request, response) {
  if (!['GET', 'POST'].includes(request.method)) {
    response.status(405).setHeader('Allow', 'GET, POST').json({ error: { code: 'METHOD_NOT_ALLOWED', message: 'Method not allowed.', retryable: false } });
    return;
  }
  if (request.method === 'POST' && request.headers['x-signalword-action'] !== 'acknowledge') {
    response.status(400).json({ error: { code: 'INVALID_REQUEST' } }); return;
  }
  const token = Array.isArray(request.query.token) ? request.query.token[0] : request.query.token;
  const result = await proxyPublicEvent({
    token: typeof token === 'string' ? token : '',
    upstreamOrigin: process.env.SIGNALWORD_PUBLIC_EVENT_ORIGIN ?? '',
    method: request.method,
  });
  for (const [name, value] of Object.entries(result.headers)) response.setHeader(name, value);
  response.status(result.status).json(result.body);
}
