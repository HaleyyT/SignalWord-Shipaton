import { createServer } from 'vite';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const { chromium } = await import(process.env.SIGNALWORD_PLAYWRIGHT_MODULE ?? '@playwright/test');

// Browser behavior uses a deterministic API stub. Database/Edge integration has
// separate suites; this must not be described as a live-provider E2E test.
const server = process.env.SIGNALWORD_VIEWER_TEST_URL ? null : await createServer({ root: fileURLToPath(new URL('../', import.meta.url)), server: { host: '127.0.0.1', port: 4174, strictPort: true } });
await server?.listen();
let browser;
const token = 'a'.repeat(43);
const event = {
  kind: 'test', displayName: 'Alex', state: 'active',
  triggeredAt: '2026-09-26T08:00:00Z', lastUpdatedAt: '2026-09-26T08:00:00Z',
  guidance: { summary: 'TEST. Contact Alex directly to complete the rehearsal.' },
};
try {
  browser = await chromium.launch({ headless: true, ...(process.env.SIGNALWORD_CHROME_PATH ? { executablePath: process.env.SIGNALWORD_CHROME_PATH } : {}) });
  const page = await browser.newPage({ viewport: { width: 320, height: 700 } });
  let posts = 0;
  let failPost = true;
  await page.route('**/v1/public/events/*', async route => {
    if (route.request().method() === 'POST') {
      posts++;
      assert.equal(route.request().headers()['x-signalword-action'], 'acknowledge');
      await route.fulfill({ status: failPost ? 503 : 200, json: failPost ? {} : { acknowledged: true } });
    } else await route.fulfill({ json: event });
  });
  await page.goto(`${process.env.SIGNALWORD_VIEWER_TEST_URL ?? 'http://127.0.0.1:4174'}/events/${token}`);
  await page.getByRole('heading', { name: 'Alex sent an alert' }).waitFor();
  assert.equal(posts, 0, 'opening or rendering an alert must not acknowledge');
  await page.getByRole('button', { name: 'Acknowledge this alert' }).click();
  await page.getByRole('alert').waitFor();
  assert.equal(posts, 1);
  failPost = false;
  await page.getByRole('button', { name: 'Acknowledge this alert' }).click();
  await page.getByText('Acknowledged through this recipient link.', { exact: false }).waitFor();
  assert.equal(posts, 2);
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true, '320px layout must not overflow');
  await page.screenshot({ path: process.env.SIGNALWORD_VIEWER_SCREENSHOT ?? `${tmpdir()}/signalword-viewer-ack.png`, fullPage: true });

  const missed = await browser.newPage({viewport:{width:320,height:700}});
  await missed.route('**/v1/public/events/*', route => route.fulfill({json:{...event,kind:'real',cause:'missed_check_in',checkInDeadline:'2026-09-26T07:59:00Z',guidance:{summary:'Contact Alex directly.'}}}));
  await missed.goto(`${process.env.SIGNALWORD_VIEWER_TEST_URL ?? 'http://127.0.0.1:4174'}/events/${token}`);
  await missed.getByRole('heading',{name:'Alex missed a check-in'}).waitFor();
  await missed.getByText('This does not confirm danger.',{exact:false}).waitFor();
  assert.equal(await missed.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth),true);

  // A withdrawal response can be lost after consent was revoked. Retrying must
  // repeat withdrawal, never switch the user's choice back to confirmation.
  const consent = await browser.newPage({ viewport: { width: 320, height: 700 } });
  const actions = [];
  await consent.route('**/api/v1/contacts/confirm/*', async route => {
    const action = route.request().headers()['x-signalword-action'] ?? 'confirm';
    actions.push(action);
    await route.fulfill(actions.length === 1
      ? { status: 503, json: { retryable: true } }
      : { status: 200, json: { withdrawn: true } });
  });
  await consent.goto(`${process.env.SIGNALWORD_VIEWER_TEST_URL ?? 'http://127.0.0.1:4174'}/confirm/${token}`);
  await consent.getByRole('button', { name: 'Withdraw trusted-contact consent' }).click();
  await consent.getByRole('heading', { name: 'Withdrawal is not confirmed yet' }).waitFor({ timeout: 3000 });
  assert.equal(await consent.getByText('No confirmation was recorded.', { exact: false }).count(), 0);
  await consent.getByRole('button', { name: 'Retry withdrawal' }).click();
  await consent.getByRole('heading', { name: 'Consent withdrawn' }).waitFor();
  assert.deepEqual(actions, ['withdraw', 'withdraw']);
  assert.equal(await consent.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true);

  const unavailable = await browser.newPage();
  await unavailable.route('**/v1/public/events/*', route => route.fulfill({ status: 404, json: {} }));
  await unavailable.goto(`${process.env.SIGNALWORD_VIEWER_TEST_URL ?? 'http://127.0.0.1:4174'}/events/${token}`);
  await unavailable.getByRole('heading', { name: 'This alert link is unavailable' }).waitFor();
  assert.equal(await unavailable.getByRole('button', { name: 'Acknowledge this alert' }).count(), 0);
  console.log('Browser regression passed: explicit acknowledgement, failed POST recovery, revoked link, missed-check-in guidance, 320px layout.');
} finally { await browser?.close(); await server?.close(); }
