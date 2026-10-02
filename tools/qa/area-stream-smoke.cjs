// Area streaming smoke: stands the hero a few metres either side of every door (screenshots at each), asserting the area ahead is built
// AND drawn before the player gets there (no hole / pop-in), that far areas are hidden, and that no load veil appears after the first one.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5405/?offline' DM_QA_ARTIFACT_DIR=/tmp/area-stream node tools/qa/area-stream-smoke.cjs
// Env: DM_QA_DOORS (comma list of door ids, default a route of six)  DM_QA_VIEWPORT (default 1280x800)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5405/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'area-stream');
const VIEW = (process.env.DM_QA_VIEWPORT || '1280x800').split('x').map(Number);
const DOORS = (process.env.DM_QA_DOORS || 'chapter_graves,graves_nave,nave_sanctum,graves_ossuary,nave_fen,chapter_acre').split(',').filter(Boolean);
fs.mkdirSync(OUT, { recursive: true });
let failed = 0;
const check = (ok, msg) => { console.log((ok ? 'ok   ' : 'FAIL ') + msg); if (!ok) failed++; };

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: VIEW[0], height: VIEW[1] } });
  page.setDefaultTimeout(150000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => {
    localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false }));
    window.__veils = 0;
    new MutationObserver((ms) => { for (const m of ms) for (const n of m.addedNodes) if (n.classList?.contains('dm-loadveil')) window.__veils++; }).observe(document, { childList: true, subtree: true });
  });
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `as_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForSelector('.dm-loadveil', { timeout: 20000 }).catch(() => {});
  await page.screenshot({ path: path.join(OUT, '00-veil.png') }).catch(() => {});
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 120000 });
  await page.screenshot({ path: path.join(OUT, '00-first-frame.png') });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.freeze?.(true); });
  const veilsAtPlay = await page.evaluate(() => window.__veils);
  check(veilsAtPlay === 1, `exactly one veil at mount (${veilsAtPlay})`);
  const info = await page.evaluate(async () => (await import('/src/content/areas.ts')).DOORS.map((d) => ({ id: d.id, a: d.a, b: d.b, rect: d.rect, axis: d.axis })));
  for (const id of DOORS) {
    const d = info.find((x) => x.id === id);
    const cx = (d.rect.x0 + d.rect.x1) / 2, cz = (d.rect.z0 + d.rect.z1) / 2;
    // Which side is `a`? Step 7 m back from the door centre toward each room's interior along the door axis.
    const rects = await page.evaluate(async ([a, b]) => { const A = (await import('/src/content/areas.ts')).AREAS; return { a: A[a].rect, b: A[b].rect }; }, [d.a, d.b]);
    const mid = (r) => ({ x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2 });
    for (const [from, to, rect] of [[d.a, d.b, rects.a], [d.b, d.a, rects.b]]) {
      const m = mid(rect);
      const vx = d.axis === 'x' ? Math.sign(m.x - cx) : 0, vz = d.axis === 'z' ? Math.sign(m.z - cz) : 0;
      const px = cx + vx * 8, pz = cz + vz * 8;
      await page.evaluate(([x, z]) => { const dd = window.__cwDebug; dd.teleport(x, z); dd.advance(0.4); }, [px, pz]);
      const s = await page.evaluate(() => window.__cwDebug.stream());
      check(s.shown.includes(from) && s.shown.includes(to), `${id}: standing in ${from}, both ${from} and ${to} are drawn (shown: ${s.shown.join(',')})`);
      check(s.built.includes(to), `${id}: ${to} is built before the door is crossed`);
      await page.screenshot({ path: path.join(OUT, `${id}-in-${from}.png`) });
    }
  }
  // Far areas are hidden: stand in the Chapterhouse, the Pyre/Sanctum must not be drawn.
  await page.evaluate(() => { const dd = window.__cwDebug; dd.goto('chapterhouse'); dd.advance(0.4); });
  const far = await page.evaluate(() => window.__cwDebug.stream());
  check(!far.shown.includes('pyre') && !far.shown.includes('sanctum'), `far areas hidden from the Chapterhouse (shown: ${far.shown.join(',')})`);
  // Teleport hops (waystone / recall style): no new veil, destination drawn at once.
  for (const a of ['pyre', 'fen', 'chapterhouse', 'coliseum']) {
    await page.evaluate((x) => { const dd = window.__cwDebug; dd.goto(x); dd.advance(0.1); }, a);
    const s = await page.evaluate(() => window.__cwDebug.stream());
    check(s.shown.includes(a), `teleport to ${a}: drawn immediately`);
    await page.screenshot({ path: path.join(OUT, `tp-${a}.png`) });
  }
  const veils = await page.evaluate(() => window.__veils);
  check(veils === 1, `no further veil after mount (${veils} total)`);
  const final = await page.evaluate(() => window.__cwDebug.stream());
  console.log('final', JSON.stringify(final));
  check(errors.length === 0, `no page errors ${errors.slice(0, 3).join(' | ')}`);
  await browser.close();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
