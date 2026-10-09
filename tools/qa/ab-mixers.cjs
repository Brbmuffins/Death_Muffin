// CPU-snappy A/B harness, copied from the ab-new regression investigation (2026-10-02): live AnimationMixer / action counts per body.
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE);
const URL = process.env.DM_QA_URL, AREA = process.env.DM_QA_AREA || 'graves';
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `mx_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email'); if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, AREA);
  const pre = await page.evaluate(async () => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim(); const p = d.player;
    const m = sc.discipline.mods; const cap = 15;
    for (let i = 0; i < cap; i++) { const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5; sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area); sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 20, attackSpeedMult: 1 }); }
    d.advance(1.5);
    const roster = (await import('/server/rules/content/areas.ts')).AREAS[p.area].enemies.map((e) => e.id);
    roster.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, false));
    window.__ring = () => roster.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, false)); window.__d = d; window.__sc = sc;
    return 1;
  });
  await page.waitForTimeout(8000);
  const res = await page.evaluate(async () => {
    const sc = window.__sc, d = window.__d, sim = d.sim(), roster = null;
    for (let i = 0; i < 20; i++) { d.advance(0.5, 1 / 60, false); if (d.counts().enemies < 10) window.__ring(); }
    const views = sc.views;
    const stat = (map) => { const o = { n: 0, skinnedMeshes: 0, actions: 0, activeActions: 0, activeBindings: 0, tracksActive: 0, rootNodes: 0, bones: 0, attached: 0, extraTracksPerBody: [] }; for (const v of map.values()) { const c = v.c; const mx = c.mixer; if (!mx) continue; o.n++; o.actions += mx._actions.length; o.activeActions += mx._nActiveActions; o.activeBindings += mx._nActiveBindings; o.attached += c.attached.length; let sk = 0, nodes = 0, bones = 0; c.root.traverse((x) => { nodes++; if (x.isSkinnedMesh) sk++; if (x.isBone) bones++; }); o.skinnedMeshes += sk; o.rootNodes += nodes; o.bones += bones; } for (const k of ['actions', 'activeActions', 'activeBindings', 'skinnedMeshes', 'rootNodes', 'bones', 'attached']) o[k] = +(o[k] / Math.max(1, o.n)).toFixed(2); delete o.extraTracksPerBody; delete o.tracksActive; return o; };
    // Per-clip track counts for the thrall rig and the hero.
    const th = [...views.thralls.values()][0]; const clips = th ? Object.fromEntries([...th.c.actions.entries()].map(([k, a]) => [k, a.getClip().tracks.length + '/' + a.getClip().duration.toFixed(2)])) : null;
    // measure per-frame time for the thrall update loop alone
    const ts = [...views.thralls.values()];
    const t0 = performance.now(); for (let i = 0; i < 200; i++) for (const v of ts) v.c.update(1 / 60); const thrallUpdMs = (performance.now() - t0) / 200 / Math.max(1, ts.length);
    const es = [...views.enemies.values()];
    const t1 = performance.now(); for (let i = 0; i < 200; i++) for (const v of es) v.c.update(1 / 60); const enemyUpdMs = (performance.now() - t1) / 200 / Math.max(1, es.length);
    const active = {}; for (const v of views.thralls.values()) { const key = [...v.c.actions.entries()].filter(([k, a]) => a.enabled && a.getEffectiveWeight() > 0).map(([k, a]) => k + ':' + a.getEffectiveWeight().toFixed(2)).join(','); const en = [...v.c.actions.entries()].filter(([k, a]) => a.isRunning()).map(([k]) => k).join(','); active[key + ' | running ' + en] = (active[key + ' | running ' + en] || 0) + 1; } const eact = {}; for (const v of views.enemies.values()) { if (!v.c.mixer) continue; const en = [...v.c.actions.entries()].filter(([k, a]) => a.isRunning()).map(([k]) => k).join(','); eact[en] = (eact[en] || 0) + 1; }
    return { thralls: stat(views.thralls), enemies: stat(views.enemies), corpses: stat(views.corpses), nCorpses: views.corpses.size, thrallClips: clips, active, eact, thrallUpdMsPerBody: +thrallUpdMs.toFixed(4), enemyUpdMsPerBody: +enemyUpdMs.toFixed(4), counts: d.counts() };
  });
  console.log(JSON.stringify(res, null, 1));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
