// This page is separate from recipient routes so their strict CSP stays intact.
// Tokens go directly to the native bridge, never to a URL, log, or browser storage.
const status = document.getElementById('status');
const retry = document.getElementById('retry');
const sitekey = new URL(location.href).searchParams.get('sitekey');
const bridge = window.webkit?.messageHandlers?.signalwordVerification;
let widget;
let completed = false;
function unavailable() {
  completed = false;
  status.textContent = 'Verification could not finish. Check your connection and try again.';
  retry.hidden = false;
}
if (!bridge || !/^[A-Za-z0-9_-]{10,100}$/.test(sitekey ?? '')) {
  status.textContent = 'Open verification from the SignalWord app. If this continues, contact support.';
} else {
  const script = document.createElement('script');
  script.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
  script.onerror = unavailable;
  script.onload = () => {
    widget = window.turnstile.render('#challenge', {
      sitekey,
      action: 'signup',
      theme: 'auto',
      callback(token) {
        if (completed || typeof token !== 'string' || !token.length || token.length > 2048 || /\s/.test(token)) return;
        completed = true;
        retry.hidden = true;
        status.textContent = 'Verification complete. Returning to SignalWord…';
        bridge.postMessage(token);
      },
      'error-callback': unavailable,
      'expired-callback': unavailable,
      'timeout-callback': unavailable,
    });
    status.textContent = 'Complete the verification below.';
  };
  retry.addEventListener('click', () => {
    retry.hidden = true;
    if (widget === undefined) { location.reload(); return; }
    completed = false;
    window.turnstile.reset(widget);
    status.textContent = 'Complete the verification below.';
  });
  document.head.appendChild(script);
}
