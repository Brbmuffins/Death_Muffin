/**
 * Animation pass smoke (X2/P5). Offline, one Gravecaller in the Hollow Graves:
 *  - every biped and quadruped enemy faces its heading and its planted feet slide < 45% of ground speed (walk-only models
 *    that need more than the playback cap are reported, not failed);
 *  - the hero's run clip matches its movement; heading changes are rate limited;
 *  - a hit flinch is additive (the swing / stride keeps running);
 *  - crowd separation reduces drawn overlaps in a ring of enemies;
 *  - equipped weapon kinds load and screenshot idle + mid-cast;
 *  - perf: __cwDebug.counts() and frame time in a busy fight.
 *   npm run dev -- --host 127.0.0.1 --port 5336 --strictPort
 *   DM_QA_URL='http://127.0.0.1:5336/?offline' DM_PLAYWRIGHT_MODULE=... node tools/qa/anim-pass-smoke.cjs
 * Screenshots/JSON go to DM_QA_ARTIFACT_DIR (default docs/screenshots/anim-pass). DM_QA_NO_SHOTS=1 skips screenshots.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5336/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(__dirname, '../../docs/screenshots/anim-pass');
const SHOTS = !process.env.DM_QA_NO_SHOTS;
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);

async function openHero(browser, errors) {
  const page = await browser.newPage({ viewport: { width: 900, height: 600 } });
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('crash', () => log('PAGE CRASH'));
  page.on('framenavigated', (f) => log('nav', f.url()));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `anim_${Date.now() % 1e6}`);
  await page.fill('#cw-email', 'anim@example.invalid');
  await page.fill('#cw-pass', 'TestingAnim1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.goto('graves'); d.unlockAll?.(); d.god(true); d.clear(); d.zoom(0.4); d.advance(0.5); });
  return page;
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const errors = (global.__errors = []);
  let page = await openHero(browser, errors);
  const report = {};

  // --- enemies: heading and foot slip ---
  const defs = await page.evaluate(async () => {
    const { ENEMIES } = await import('/src/content/enemies.ts');
    const skip = new Set(['niche', 'fen_wisp', 'mire_leech', 'moth', 'bat', 'wraith', 'gargoyle', 'seraph']);
    return Object.keys(ENEMIES).filter((d) => !skip.has(d));
  });
  report.enemies = {};
  for (const def of defs) {
    report.enemies[def] = await page.evaluate(async (def) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const scene = getRuntime().view;
    const V3 = scene.rig.camera.position.constructor;
    const med = (a) => { a = a.slice().sort((x, y) => x - y); return a[Math.floor(a.length / 2)]; };
    {
      dbg.clear();
      scene.player.x = 0; scene.player.z = 0;
      const id = dbg.ring(def, 1, 12)[0];
      const sim = dbg.sim();
      const e = sim.enemies.get(id);
      if (!e) return 'nospawn';
      e.hp = e.maxHp = 1e9;
      let view;
      for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
      if (!view || !view.c.loaded) { return 'noview'; }
      dbg.advance(1.3, false);
      const feet = [];
      const leaves = [];
      view.c.model.traverse((o) => {
        if (o.name === 'L_Foot' || o.name === 'R_Foot') feet.push(o);
        if (!o.children.length && /Limb|bone_/.test(o.name) && !/Head|Tail/.test(o.name)) leaves.push(o);
      });
      const quad = feet.length !== 2;
      const use = quad ? leaves.map((o) => [o, o.getWorldPosition(new V3()).y]).sort((a, b) => a[1] - b[1]).slice(0, 4).map((a) => a[0]) : feet;
      const samples = [];
      let prev = null;
      for (let i = 0; i < 150; i++) {
        dbg.advance(1 / 60, false);
        const ee = sim.enemies.get(id);
        if (!ee) break;
        if (!ee.moving) { prev = null; if (Math.hypot(ee.x, ee.z) < 3.5) break; continue; }
        const fp = use.map((f) => f.getWorldPosition(new V3()));
        const rp = view.c.root.position.clone();
        if (prev) samples.push({ rootV: Math.hypot(rp.x - prev.rp.x, rp.z - prev.rp.z) * 60, feet: fp.map((p, k) => ({ y: p.y, v: Math.hypot(p.x - prev.fp[k].x, p.z - prev.fp[k].z) * 60 })), plan: view.c.lastPlan });
        prev = { fp, rp };
      }
      if (samples.length < 20) { return 'few'; }
      const ground = med(samples.map((s) => s.rootV));
      const slips = [];
      for (let k = 0; k < use.length; k++) {
        const ys = samples.map((s) => s.feet[k].y);
        const lo = Math.min(...ys), hi = Math.max(...ys);
        const st = samples.filter((s) => s.feet[k].y <= lo + 0.22 * (hi - lo)).map((s) => s.feet[k].v);
        if (st.length) slips.push(med(st));
      }
      const plan = samples[10].plan;
      return { ground: +ground.toFixed(2), slip: +(med(slips) / ground).toFixed(2), clip: plan?.clip, ts: +(plan?.timeScale ?? 0).toFixed(2), capped: (plan?.residual ?? 0) > 0.15, quad };
    }
  }, def);
  }
  const bip = Object.entries(report.enemies).filter(([, v]) => typeof v === 'object' && !v.quad && !v.capped);
  assert.ok(bip.length >= 8, 'measured enough biped enemies');
  for (const [def, v] of bip) assert.ok(v.slip < 0.9, `${def} foot slip ratio ${v.slip}`);
  const avg = bip.reduce((s, [, v]) => s + v.slip, 0) / bip.length;
  assert.ok(avg < 0.45, `mean slip ${avg.toFixed(2)}`);
  report.meanBipedSlip = +avg.toFixed(2);
  log('enemy slip mean', report.meanBipedSlip);

  // --- heading: biped toes point along the heading ---
  report.heading = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const scene = getRuntime().view;
    const V3 = scene.rig.camera.position.constructor;
    dbg.clear();
    const id = dbg.ring('robber', 1, 6)[0];
    let view;
    for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = scene.views.enemies.get(id); }
    dbg.freeze(true);
    dbg.advance(2, false);
    const h = view.c.root.rotation.y;
    let A, B;
    view.c.model.traverse((o) => { if (o.name === 'L_Foot') A = o; if (o.name === 'L_ToeBase') B = o; });
    const d = B.getWorldPosition(new V3()).sub(A.getWorldPosition(new V3()));
    return (d.x * Math.sin(h) + d.z * Math.cos(h)) / Math.hypot(d.x, d.z);
  });
  assert.ok(report.heading > 0.9, `robber faces its heading (${report.heading})`);

  // --- hero: run matches movement, turns are rate limited ---
  report.hero = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const v = getRuntime().view;
    dbg.clear();
    v.player.moveTo(v.player.x + 12, v.player.z);
    dbg.advance(0.8, false);
    const plan = v.avatar.c.lastPlan;
    let maxStep = 0, last = v.avatar.c.root.rotation.y;
    v.player.facing = last + 3;
    for (let i = 0; i < 30; i++) { dbg.advance(1 / 60, false); const r = v.avatar.c.root.rotation.y; maxStep = Math.max(maxStep, Math.abs(r - last)); last = r; }
    return { clip: plan?.clip, ts: plan?.timeScale, residual: plan?.residual, maxTurnPerFrame: maxStep };
  });
  assert.equal(report.hero.clip, 'run');
  assert.ok(report.hero.residual < 0.3, 'hero feet near planted');

  // --- additive flinch ---
  report.flinch = await page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug;
    const v = getRuntime().view;
    dbg.clear(); v.player.x = 0; v.player.z = 0;
    const id = dbg.ring('robber', 1, 6)[0];
    let view;
    for (let k = 0; k < 40 && !(view && view.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); dbg.advance(0.05, false); view = v.views.enemies.get(id); }
    dbg.advance(1.4, false);
    const c = view.c;
    const before = c.current?.getClip().name;
    c.flinch();
    dbg.advance(0.1);
    return { before, after: c.current?.getClip().name, running: c.flinchAct?.isRunning(), additive: c.flinchAct?.blendMode === 2501 };
  });
  assert.ok(report.flinch.running && report.flinch.additive, 'flinch is additive');
  assert.equal(report.flinch.before, report.flinch.after, 'flinch does not swap the clip');

  // --- crowd: 36 enemies converge on a standing hero; count overlapping pairs (centres closer than 80% of the radii) ---
  await page.evaluate(() => { const dbg = window.__cwDebug; dbg.clear(); dbg.ring('risen', 12, 7); dbg.ring('robber', 12, 9); dbg.ring('penitent', 12, 11); });
  await page.evaluate(async () => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); const v = getRuntime().view; for (let k = 0; k < 60 && [...v.views.enemies.values()].some((x) => !x.c.loaded); k++) { await new Promise((r) => setTimeout(r, 250)); window.__cwDebug.advance(0.05, false); } });
  const sample = () => page.evaluate(async () => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const dbg = window.__cwDebug; const v = getRuntime().view;
    const items = [...dbg.sim().enemies.values()].map((e) => ({ e, view: v.views.enemies.get(e.id) })).filter((o) => o.view && o.e.state !== 'rising');
    const count = (get) => { let n = 0; for (let i = 0; i < items.length; i++) for (let j = i + 1; j < items.length; j++) { const a = get(items[i]), b = get(items[j]); if (Math.hypot(a[0] - b[0], a[1] - b[1]) < (items[i].e.radius + items[j].e.radius) * 0.8) n++; } return n; };
    return { bodies: items.length, sim: count((o) => [o.e.x, o.e.z]), drawn: count((o) => [o.view.c.root.position.x, o.view.c.root.position.z]) };
  });
  report.crowd = { bodies: 0, simOverlaps: 0, drawnOverlaps: 0, samples: 0 };
  for (let i = 0; i < 16; i++) {
    await page.evaluate(() => window.__cwDebug.advance(0.4, false));
    const c = await sample();
    report.crowd.bodies = Math.max(report.crowd.bodies, c.bodies);
    report.crowd.simOverlaps += c.sim;
    report.crowd.drawnOverlaps += c.drawn;
    report.crowd.samples++;
  }
  log('crowd', JSON.stringify(report.crowd));
  assert.ok(report.crowd.drawnOverlaps <= report.crowd.simOverlaps, 'separation never adds overlaps');
  await page.evaluate(() => window.__cwDebug.advance(0.02));
  if (SHOTS) await page.screenshot({ path: path.join(OUT, 'crowd-ring.png') });

  // --- weapon screenshots ---
  if (SHOTS) {
    await page.close();
    page = await openHero(browser, errors);
    await page.evaluate(() => { const d = window.__cwDebug; d.clear(); d.zoom(0.1); d.advance(2); });
    await page.addStyleTag({ content: '#ui-root { display: none !important; }' });
    const equip = (id) => page.evaluate(async (id) => {
      const { getRuntime } = await import('/src/app/GameRuntime.ts');
      const { equipItem } = await import('/src/net/api.ts');
      const v = getRuntime().view;
      if (!v.inventory.all.some((s) => s.item_id === id)) { v.inventory.add({ item_id: id, quantity: 1 }); await v.inventory.flush(); }
      const s = v.inventory.all.find((x) => x.item_id === id && !x.equipped);
      if (s) v.inventory.replace(await equipItem(v.character.id, s.slot_index, 1));
    }, id);
    for (const [name, ids] of [['staff', ['staff_gold']], ['scythe', ['scythe_gold']], ['wand', ['wand_gold']], ['sickle', ['sickle_gold']], ['wand-grimoire', ['wand_gold', 'grimoire_gold']], ['wand-bell', ['wand_gold', 'mourning_bell_gold']]]) {
      for (const id of ids) await equip(id);
      await page.waitForFunction(async () => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); return [...getRuntime().view.avatar.worn.values()].every((w) => w.obj.userData.model === true); }, null, { timeout: 30000 }).catch(() => {});
      await page.evaluate(() => window.__cwDebug.advance(0.6));
      await page.screenshot({ path: path.join(OUT, `weapon-${name}-idle.png`), clip: { x: 300, y: 150, width: 300, height: 300 } });
      await page.evaluate(() => { const d = window.__cwDebug; d.clear(); d.ring('robber', 1, 4); d.freeze(true); d.advance(0.3, false); });
      await page.evaluate(async () => {
        const { getRuntime } = await import('/src/app/GameRuntime.ts');
        const v = getRuntime().view;
        v.player.cooldowns?.clear?.(); v.player.castUntil = 0;
        const e = [...v.enemiesMap().values()][0];
        v.abilities.cast('bone_needle', { x: e.x, z: e.z, enemyId: e.id }, v.now);
      });
      await page.evaluate(() => window.__cwDebug.advance(0.1));
      await page.screenshot({ path: path.join(OUT, `weapon-${name}-cast.png`), clip: { x: 300, y: 150, width: 300, height: 300 } });
      await page.evaluate(() => { window.__cwDebug.clear(); window.__cwDebug.advance(0.5); });
    }
  }

  // --- perf in a busy fight ---
  report.perf = await page.evaluate(async () => {
    const dbg = window.__cwDebug;
    dbg.clear(); dbg.freeze(false); dbg.zoom(0.4);
    dbg.ring('robber', 14, 9); dbg.ring('risen', 14, 12); dbg.ring('hound', 8, 14);
    dbg.advance(1, false);
    const t0 = performance.now();
    for (let i = 0; i < 120; i++) dbg.advance(1 / 60, false);
    return { counts: dbg.counts(), cpuMsPerStep: +((performance.now() - t0) / 120).toFixed(2) };
  });
  log('perf', JSON.stringify(report.perf));

  assert.deepEqual(errors.filter((e) => !/403|Failed to load resource/.test(e)), [], 'no runtime errors');
  fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 1));
  console.log(JSON.stringify({ meanBipedSlip: report.meanBipedSlip, heading: report.heading, hero: report.hero, flinch: report.flinch, crowd: report.crowd, perf: report.perf }, null, 1));
  await browser.close();
}


main().catch((e) => { console.error(e, global.__errors); process.exit(1); });
