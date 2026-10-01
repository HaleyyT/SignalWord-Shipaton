import { createServer } from 'vite';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const server = await createServer({ root: fileURLToPath(new URL('../', import.meta.url)), server: { host: '127.0.0.1', port: 4175, strictPort: true } });
await server.listen();
let browser;
try {
  browser = await chromium.launch({ headless: true, ...(process.env.SIGNALWORD_CHROME_PATH ? { executablePath: process.env.SIGNALWORD_CHROME_PATH } : {}) });
  const page = await browser.newPage({ viewport: { width: 320, height: 700 } });
  await page.addInitScript(() => {
    window.testTokens = [];
    window.webkit = { messageHandlers: { signalwordVerification: { postMessage(token) { window.testTokens.push(token); } } } };
  });
  // Simulated provider: validates our UI/bridge behavior, not real bot protection.
  await page.route('https://challenges.cloudflare.com/**', route => route.fulfill({ contentType: 'application/javascript', body: `
    window.turnstile = { render(target, options) {
      window.challengeOptions = options;
      const button = document.createElement('button'); button.textContent = 'Simulate verification';
      button.onclick = () => options.callback('simulated-ephemeral-token');
      document.querySelector(target).appendChild(button); return 'test-widget';
    }, reset() {} };` }));
  await page.goto('http://127.0.0.1:4175/onboarding/verify.html?sitekey=public-test-site-key');
  await page.getByRole('button', { name: 'Simulate verification' }).click();
  assert.deepEqual(await page.evaluate(() => window.testTokens), ['simulated-ephemeral-token']);
  assert.match(await page.getByRole('status').innerText(), /Verification complete/);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true);
  await page.evaluate(() => window.challengeOptions['expired-callback']());
  assert.equal(await page.getByRole('button', { name: 'Try again' }).isVisible(), true);
  console.log('PASS signup page token bridge, expiry recovery and 320px layout with simulated provider.');
} finally { await browser?.close(); await server.close(); }
