#!/usr/bin/env node
// Click Approve or Reject on the AI on HKS dashboard for one waiting order. Usage: node approve-test.js <app name> <Approve|Reject> <shot>
const { chromium } = require('playwright'); const env = process.env; const BASE = env.MORPHEUS_URL.replace(/\/$/, '');
const [name, button, shot] = process.argv.slice(2);
(async () => { const b = await chromium.launch(); const page = await (await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } })).newPage();
  await page.goto(`${BASE}/login`); await page.fill('#username', env.MORPHEUS_UI_USER); await page.fill('#password', env.MORPHEUS_UI_PASSWORD);
  await Promise.all([page.waitForURL(u => !u.toString().includes('/login'), { timeout: 60000 }), page.press('#password', 'Enter')]);
  await page.goto(`${BASE}/operations/dashboard`, { waitUntil: 'networkidle' }); await page.waitForSelector('#aih-root');
  const row = page.locator('.aih-appr', { hasText: name });
  if (!(await row.count())) { console.log('NO WAITING ROW FOR', name); await b.close(); return; }
  await Promise.all([page.waitForURL(/done=/, { timeout: 60000 }), row.locator('button', { hasText: button }).click()]);
  await page.waitForSelector('#aih-root'); await page.waitForTimeout(1500);
  console.log('URL', page.url().replace(BASE, '')); console.log('MESSAGE', await page.locator('.aih-alert').first().innerText().catch(() => 'none'));
  console.log('STILL WAITING', await page.locator('.aih-appr', { hasText: name }).count());
  await page.locator('#aih-root').screenshot({ path: shot, clip: undefined }).catch(() => {}); await b.close();
})().catch(e => { console.log('FAILED', e.message.slice(0, 300)); process.exit(1); });
