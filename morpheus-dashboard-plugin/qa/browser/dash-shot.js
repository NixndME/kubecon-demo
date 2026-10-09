#!/usr/bin/env node
// Screenshot Operations > Dashboard (AI on HKS) in dark and light, and print what it shows.
// Usage: node dash-shot.js <out prefix> [click a chat row: name]
const { chromium } = require('playwright');
const env = process.env; const BASE = env.MORPHEUS_URL.replace(/\/$/, '');
const [prefix, openRow] = process.argv.slice(2);
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } })).newPage();
  const errors = []; page.on('pageerror', e => errors.push(e.message)); page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  await page.goto(`${BASE}/login`); await page.fill('#username', env.MORPHEUS_UI_USER); await page.fill('#password', env.MORPHEUS_UI_PASSWORD);
  await Promise.all([page.waitForURL(u => !u.toString().includes('/login'), { timeout: 60000 }), page.press('#password', 'Enter')]);
  await page.goto(`${BASE}/operations/dashboard`, { waitUntil: 'networkidle' });
  await page.waitForSelector('#aih-root', { timeout: 60000 }).catch(() => console.log('NO #aih-root'));
  await page.waitForTimeout(2000);
  if (openRow) { await page.locator(`details[data-key="${openRow}"] > summary`).click().catch(() => {}); await page.waitForTimeout(800); }
  console.log('TEXT', (await page.locator('#aih-root').innerText().catch(() => '')).replace(/\s+/g, ' ').slice(0, 1600));
  for (const mode of ['dark', 'light']) {
    await page.evaluate(m => document.documentElement.setAttribute('data-mode', m), mode); await page.waitForTimeout(500);
    await page.screenshot({ path: `${prefix}-${mode}.png`, fullPage: true });
  }
  console.log('ERRORS', JSON.stringify(errors.filter(e => !/createRoot/.test(e)).slice(0, 5)));
  await b.close();
})().catch(e => { console.log('FAILED', e.message.slice(0, 300)); process.exit(1); });
