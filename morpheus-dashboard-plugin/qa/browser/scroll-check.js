const { chromium } = require('playwright'); const env = process.env; const BASE = env.MORPHEUS_URL.replace(/\/$/, '');
(async () => { const b = await chromium.launch(); const page = await (await b.newContext({ ignoreHTTPSErrors: true, viewport: { width: 1500, height: 1000 } })).newPage();
  await page.goto(`${BASE}/login`); await page.fill('#username', env.MORPHEUS_UI_USER); await page.fill('#password', env.MORPHEUS_UI_PASSWORD);
  await Promise.all([page.waitForURL(u => !u.toString().includes('/login'), { timeout: 60000 }), page.press('#password', 'Enter')]);
  await page.goto(`${BASE}/operations/dashboard`, { waitUntil: 'networkidle' }); await page.waitForSelector('#aih-root');
  const r = await page.$$eval('.aih-pc-body, .aih-bars-scroll, .aih-act-scroll', els => els.map(e => { const rows = e.querySelectorAll('.aih-pc').length || (e.querySelectorAll('.aih-bars > b').length || e.querySelectorAll('.aih-act').length); e.scrollTop = 9999; return `${e.className}: ${rows} rows, shows ${e.clientHeight}px of ${e.scrollHeight}px, scrolled to ${e.scrollTop}`; }));
  console.log(r.join('\n')); await b.close(); })();
