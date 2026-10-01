import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source = readFileSync('apps/viewer/public/onboarding/verify.js', 'utf8');
function page({ bridge = true, sitekey = 'public-test-site-key' } = {}) {
  const messages = [], elements = { status: {}, retry: { addEventListener(_, fn) { this.click = fn; } } };
  let script, options, resets = 0;
  const context = {
    URL, location: { href: `https://www.signalword.app/onboarding/verify.html?sitekey=${sitekey}`, reload() {} },
    document: { getElementById: id => elements[id], createElement: () => ({}), head: { appendChild(value) { script = value; } } },
    window: { ...(bridge ? { webkit: { messageHandlers: { signalwordVerification: { postMessage: value => messages.push(value) } } } } : {}),
      turnstile: { render(_, value) { options = value; return 'widget'; }, reset() { resets++; } } },
  };
  vm.runInNewContext(source, context);
  script?.onload();
  return { messages, elements, script, get options() { return options; }, get resets() { return resets; } };
}
test('signup challenge sends one bounded token through the native bridge', () => {
  const p = page();
  assert.equal(p.options.action, 'signup');
  for (const invalid of ['', 'with space', 'x'.repeat(2049), null]) p.options.callback(invalid);
  assert.deepEqual(p.messages, []);
  p.options.callback('ephemeral-token'); p.options.callback('duplicate-token');
  assert.deepEqual(p.messages, ['ephemeral-token']);
});
test('signup challenge fails closed outside the app or without valid configuration', () => {
  for (const config of [{ bridge: false }, { sitekey: 'bad' }]) {
    const p = page(config);
    assert.equal(p.script, undefined);
    assert.match(p.elements.status.textContent, /Open verification from the SignalWord app/);
  }
});
test('expired challenge offers a retry instead of reusing its old token', () => {
  const p = page();
  p.options['expired-callback']();
  assert.equal(p.elements.retry.hidden, false);
  p.elements.retry.click();
  assert.equal(p.resets, 1);
  assert.deepEqual(p.messages, []);
});
test('only the isolated onboarding page permits Cloudflare scripts', () => {
  const config = JSON.parse(readFileSync('apps/viewer/vercel.json', 'utf8'));
  const policies = path => config.headers.filter(rule => new RegExp(`^${rule.source}$`).test(path))
    .flatMap(rule => rule.headers).filter(header => header.key === 'Content-Security-Policy');
  assert.equal(policies('/onboarding/verify.html').length, 1);
  assert.match(policies('/onboarding/verify.html')[0].value, /script-src 'self' https:\/\/challenges.cloudflare.com/);
  for (const path of ['/events/private-token', '/confirm/private-token', '/index.html']) {
    assert.equal(policies(path).length, 1);
    assert.ok(!policies(path)[0].value.includes('cloudflare'));
  }
});
