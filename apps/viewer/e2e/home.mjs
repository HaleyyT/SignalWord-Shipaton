import { createServer } from 'vite';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { chromium } from '@playwright/test';
const origin = process.env.SIGNALWORD_VIEWER_TEST_URL ?? 'http://127.0.0.1:4176';
const server = process.env.SIGNALWORD_VIEWER_TEST_URL ? null : await createServer({ root: fileURLToPath(new URL('../', import.meta.url)), server: { host: '127.0.0.1', port: 4176, strictPort: true } });
await server?.listen();
let browser;
try {
  browser = await chromium.launch({ headless: true, ...(process.env.SIGNALWORD_CHROME_PATH ? { executablePath: process.env.SIGNALWORD_CHROME_PATH } : {}) });
  for (const colorScheme of ['dark', 'light']) {
    // 305px covers the usable area of a 320px desktop viewport with a scrollbar.
    for (const width of [305, 320, 390, 768, 1024, 1440, 1920]) {
      const page = await browser.newPage({ viewport: { width, height: 900 }, colorScheme, reducedMotion: 'reduce' });
      const errors = [];
      const privateRequests = [];
      page.on('pageerror', error => errors.push(error.message));
      page.on('request', request => { if (/\/v1\/|supabase/.test(request.url())) privateRequests.push(request.url()); });
      await page.goto(origin);
      await page.getByRole('heading', { level: 1, name: 'Private phrase. Trusted response.' }).waitFor();
      // React may mount the image after the initial document load event.
      // Wait for its real network load instead of racing a hosted CDN response.
      await page.waitForFunction(() => {
        const img = document.querySelector('.home-photo img');
        return img?.complete && img.naturalWidth > 0;
      });
      const layout = await page.evaluate(() => ({
        viewport: innerWidth, available: document.documentElement.clientWidth,
        content: document.documentElement.scrollWidth,
        outside: [...document.querySelectorAll('body *')].filter(el => el.getBoundingClientRect().right > innerWidth + 1)
          .slice(0, 8).map(el => ({ tag: el.tagName, class: el.className, right: el.getBoundingClientRect().right })),
      }));
      if (layout.content > layout.viewport) await page.screenshot({ path: `/tmp/signalword-home-overflow-${width}.png`, fullPage: true });
      assert.ok(layout.content <= layout.viewport, `${width}px overflow: ${JSON.stringify(layout)}`);
      await page.keyboard.press('Tab');
      await page.getByRole('link', { name: 'Skip to content' }).press('Enter');
      assert.equal(new URL(page.url()).hash, '#main');
      const navigation = page.getByRole('navigation', { name: 'Main navigation' });
      for (const [name, id] of [['How it works', 'how-it-works'], ['Why SignalWord', 'why-signalword']]) {
        await navigation.getByRole('link', { name, exact: true }).click();
        await page.waitForFunction(id => document.activeElement?.id === id, id);
        assert.equal(new URL(page.url()).pathname, '/');
        assert.equal(new URL(page.url()).hash, '#' + id);
        assert.equal(await page.locator('#' + id).evaluate(el => {
          const rect = el.getBoundingClientRect();
          return rect.top >= -1 && rect.top < innerHeight;
        }), true, name + ' target is in viewport');
      }
      await navigation.getByRole('link', { name: 'Support', exact: true }).click();
      await page.getByRole('heading', { level: 1, name: 'Use a safe route to get help.' }).waitFor();
      assert.equal(new URL(page.url()).pathname, '/support');
      assert.equal(await page.getByRole('link', { name: 'Email SignalWord support' }).getAttribute('href'), 'mailto:support@signalword.app');
      await page.getByRole('link', { name: 'SignalWord', exact: true }).click();
      await page.goto(origin + '/#why-signalword');
      await page.waitForFunction(() => document.activeElement?.id === 'why-signalword');
      await page.reload();
      await page.waitForFunction(() => document.activeElement?.id === 'why-signalword');
      await page.getByText('Does SignalWord contact emergency services?', { exact: true }).click();
      assert.equal(await page.locator('details[open]').count(), 1);
      await page.getByText('Can I download the app now?', { exact: true }).click();
      await page.getByRole('link', { name: 'support@signalword.app' }).waitFor();
      await page.getByText('Is SignalWord free?', { exact: true }).click();
      await page.getByText('It is not a subscription.', { exact: false }).waitFor();
      await page.getByRole('link', { name: 'See how SignalWord works' }).click();
      assert.equal(new URL(page.url()).hash, '#how-it-works');
      assert.deepEqual(errors, []);
      assert.deepEqual(privateRequests, [], 'Home must never access private APIs');
      await page.screenshot({ path: `/tmp/signalword-home-${colorScheme}-${width}.png`, fullPage: true });
      await page.getByRole('navigation', { name: 'Footer navigation' }).getByRole('link', { name: 'Privacy' }).click();
      assert.equal(new URL(page.url()).pathname, '/privacy');
      await page.close();
    }
  }
  console.log('PASS homepage navigation, free/one-time pricing FAQ, keyboard entry, image, no private requests, light/dark and 305/320/390/768/1024/1440/1920px layouts.');
} finally { await browser?.close(); await server?.close(); }
