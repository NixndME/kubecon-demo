const { chromium } = require('playwright'); const env = process.env; const BASE = env.MORPHEUS_URL.replace(/\/$/, '');
(async () => { const b = await chromium.launch(); const page = await (await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } })).newPage();
  await page.goto(`${BASE}/login`); await page.fill('#username', env.MORPHEUS_UI_USER); await page.fill('#password', env.MORPHEUS_UI_PASSWORD);
  await Promise.all([page.waitForURL(u => !u.toString().includes('/login'), { timeout: 60000 }), page.press('#password', 'Enter')]);
  await page.goto(`${BASE}/operations/dashboard?done=approved`, { waitUntil: 'networkidle' }); await page.waitForSelector('#aih-root'); await page.waitForTimeout(2000);
  console.log('MESSAGE', await page.locator('.aih-alert').first().innerText().catch(() => 'none'), 'URL', page.url().replace(BASE, ''));
  await page.locator('.aih-head').screenshot({ path: process.argv[2] }); await b.close(); })();
